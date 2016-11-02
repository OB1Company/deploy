/*globals Vue*/
import $ from 'jquery';
import clipboard from 'clipboard';
import Node from './node';
import ViewState from './viewState';
import NodeStates from './nodeStates';
import DigitalOcean from './digitalocean';

// Development helpers
const obRelayBranch = 'master';

// Set limits on how fast/much we poll for a new droplet to be active
// Try every 5 seconds for 10 minutes
const getDropletStateMaxAttempts = 120;
const getDropletStatePollInterval = 5000;

// Set limits on how fast/much we poll for a provisioning to finish
// Try every 30 seconds for 10 minutes
const getReadyStatusMaxAttempts = 120;
const getReadyStatusPollInterval = 30000;

// The possible data centers we'll provision nodes in
// It maps center to the avaialble data centers in that city
const availableDataCenters = {
  'nyc': [1, 2, 3],
  'sfo': [1, 2],
  'ams': [2, 3],
  'sgp': [1],
  'lon': [1],
  'fra': [1],
  'tor': [1],
  'blr': [1],
};

// cloudInitScriptTemplate is a template for an OpenBazaar provisioning script
let cloudInitScriptTemplate = $('#cloud-init-script-template').text();

// validateAPIKey checks an API key string for well-formedness
function validateAPIKey(apiKey) {
  return !!apiKey.match(/[a-z0-9]{64}/);
}

// Ask for confirmation when leaving during a provisioning.
window.onbeforeunload = function (e) {
  let stateOrdinal = ViewState.nodes[0].state.ordinal;
  if (stateOrdinal === 0 || stateOrdinal === NodeStates.enumValues.length - 1) return;
  return (e.returnValue = 'Your node isn\'t finished. Are you sure you want to leave?');
};

// Setup click-to-copy for credentials
new clipboard('[data-copy]').on('success', function (e) {
  $(e.trigger).addClass('copied');
  setTimeout(() => { $(e.trigger).removeClass('copied'); }, 3000);
});

// Create App object
const App = window.App = new Vue({
  data: ViewState,
  el: document.getElementById('container'),
  methods: {
    createvps: function createvps() {
      if (!validateAPIKey(this.apiKey)) {
        this.showBlankAPIKeyAsInvalid = true;
        return false;
      }

      provisionNode()

      // Show error message upon failure
      .fail(function (err) {
        console.log(err);
        if (err.responseJSON && err.responseJSON.message) ViewState.error = err.responseJSON.message;
        if (!err.responseJSON || !err.responseJSON.message) ViewState.error = 'Unknown error';
        if (JSON.stringify(err.status) == 401) ViewState.error = 'Check your API token';
        ViewState.nodes[0].state = NodeStates.WAITING;
        return false;
      });
    },

    deployNewNode: function () {
      ViewState.nodes = [new Node()];
    },

    downloadCredentialsFile: function () {
      var el = document.createElement('a');
      el.setAttribute('href', 'data:application/octet-stream;charset=utf-8;base64,' + btoa(`ip: ${ this.node.ipv4 }
ob_user:
  name: ${ this.node.obUser.name }
  password: ${ this.node.obUser.password }
vps_user:
  name: ${ this.node.vpsUser.name }
  password: ${ this.node.vpsUser.password }`));
      el.setAttribute('download', `openbazaar_node_${ this.node.ipv4 }.yaml`);
      el.style.display = 'none';
      document.body.appendChild(el);
      el.click();
      document.body.removeChild(el);
    },
  },

  computed: {
    node: function () { return this.nodes[0]; },

    nodeStates: () => NodeStates,

    invalidAPIKey: function () {
      if (this.apiKey === '' && this.showBlankAPIKeyAsInvalid) return true;
      return this.apiKey !== '' && !validateAPIKey(this.apiKey);
    },
  },
});

// provisionNode creates and sets up a droplet for production OpenBazaar use
function provisionNode() {
  // Get node object and update its state
  let node = ViewState.nodes[0];
  node.state = NodeStates.CREATING_DROPLET;

  // Create a DO client
  let doClient = new DigitalOcean(App.apiKey);

  // Select the region to use
  let dataCenterRegions = availableDataCenters[ViewState.datacenter];
  let region = ViewState.datacenter + dataCenterRegions[Math.floor(Math.random() * dataCenterRegions.length)];

  // Perform the provisioning
  return doClient.createDroplet({
    name: node.name,
    size: '512mb',
    region: region,
    image: 'ubuntu-14-04-x64',
    user_data: cloudInitScriptTemplate
      .replace('{{vpsPassword}}', node.vpsUser.password)
      .replace('{{obPassword}}', node.obUser.password)
      .replace('{{obRelayBranch}}', obRelayBranch),
  })

  // After creating the droplet we need to wait for it to be active
  .then(function (data) {
    return waitForCreation(doClient, data.droplet.id);
  })

  // Once it's active show a message to the user with their details and wait
  // for the provising to be finished
  .then(function (data) {
    node.ipv4 = data.droplet.networks.v4[0].ip_address;
    node.state = NodeStates.INSTALLING_OPENBAZAAR_RELAY;

    // Now just wait for everything to be ready
    return waitForReadyState(node);
  });
}

// waitForCreation polls the api X times trying to get the ip
function waitForCreation(doClient, dropletId) {
  let deferred = $.Deferred(),
    attempts = 0;

  // poll gets droplet data and if an ipv4 exists we stop, otherwise keep going
  // until the configured stopping point
  function poll() {
    doClient.getDroplet(dropletId)

    // If the request was successful check if the droplet is active. If so we
    // are done. If not try again. If we've hit the limit fail.
    .done((data) => {
      let droplet = data.droplet || {};
      if (droplet.status === 'active' && droplet.networks.v4.length) {
        return deferred.resolve(data);
      }

      if (attempts >= getDropletStateMaxAttempts) {
        deferred.reject(new Error('Too many attempts'));
      }

      attempts++;
      setTimeout(poll, getDropletStatePollInterval);
    })

    // If the request fails just reject the promise
    .fail(deferred.reject);
  }

  // Start polling
  poll();

  // Return a promise to try really hard or fail
  return deferred.promise();
}

// waitForReadyState waits for ob-relay to report the READY status
function waitForReadyState(droplet) {
  let deferred = $.Deferred(),
    attempts = 0,
    statusAddr = 'https://deploy.ob1.io/cors/status/' + droplet.ipv4;

  function poll() {
    $.get(statusAddr)

    // If the request was successful see if we're in the READY status. If so we
    // are done. If not try again unless we're at our limit.
    .always(function (data, requestStatus) {
      // Update the droplet state if the request was successful. If it's READY
      // we're done so resolve the promise with the droplet.
      if (requestStatus === 'success') {
        droplet.state = NodeStates.enumValueOf(JSON.parse(data).status);
        if (droplet.state === NodeStates.READY) return deferred.resolve(droplet);
      }

      // Ensure we haven't tried too many times
      if (attempts >= getReadyStatusMaxAttempts) return deferred.reject(new Error('Too many attempts'));

      // Try again later
      attempts++;
      setTimeout(poll, getReadyStatusPollInterval);
    });
  }

  // Start polling
  poll();

  // Return a promise to try really hard or fail
  return deferred.promise();
}
