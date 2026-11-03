const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
// Both manifests use independent Application classes. Neither may leave the gate
// at its fail-closed construction default when the persisted policy allows Relay.
for (const name of ['BridgeApplication', 'StandaloneBridgeApplication']) {
  const source = fs.readFileSync(path.join(__dirname, '../src/com/airsim/phonecontrol', name + '.java'), 'utf8');
  const restore = source.indexOf('AndroidPureLocalModeStore.initializeEgress(this);');
  assert(restore > source.indexOf('super.onCreate();'), name + ': missing policy restore');
  for (const start of ['StandaloneAgentService.start(this)', 'VoBLEGatewayService.start(this)']) {
    const position = source.indexOf(start);
    if (position !== -1) assert(restore < position, name + ': service starts before policy restore');
  }
}
console.log('Both Application entry points restore Relay policy before starting services');
