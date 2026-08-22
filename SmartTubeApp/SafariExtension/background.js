// background.js — iTube Safari Extension
//
// Receives messages from content.js and navigates the active tab to the
// smarttube:// deep link. browser.tabs.update is permitted from the background
// service worker without a user gesture, unlike window.location in content scripts.

browser.runtime.onMessage.addListener(function (message, sender) {
  if (message.action === 'openInSmartTube' && message.videoID) {
    var tabId = sender.tab && sender.tab.id;
    var url = 'smarttube://video/' + message.videoID;
    if (tabId !== undefined && tabId !== null) {
      browser.tabs.update(tabId, { url: url });
    }
  }
});
