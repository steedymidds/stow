# Connecting Dropbox accounts to Stow

Stow talks to Dropbox through a small private app that you own. You create it once; every Dropbox
account you connect (personal, work, any other) signs in through the same app.

## 1. Create the app (once, about 3 minutes)

1. Go to https://www.dropbox.com/developers/apps and choose **Create app**.
2. Choose **Scoped access**, then **Full Dropbox**. Name it anything unique, for example "My Stow".
3. On the **Permissions** tab, tick these and press **Submit**:
   - `files.metadata.read` and `files.metadata.write`
   - `files.content.read` and `files.content.write`
   - (`account_info.read` is already on; leave it.)
4. On the **Settings** tab:
   - Under **OAuth 2 → Redirect URIs**, add `http://localhost:53682/callback`.
   - Under **Allow public clients (Implicit Grant & PKCE)**, choose **Allow**.
   - If you'll connect accounts other than the one that owns the app, use **Enable additional users**.
5. Copy the **App key** (it is a public identifier, not a secret) and give it to Claude. It's saved
   in `stow-config.json`. Never share the App secret; Stow doesn't need it.

## 2. Connect an account

Ask Claude to connect it ("connect my personal Dropbox to Stow"). Dropbox's approval page opens in
your browser. Make sure you're signed into the right Dropbox account in that browser, then approve.
The token goes straight into your Mac's Keychain; nothing passes through the chat.

To connect a second account, sign out of Dropbox in the browser (or use a private window), then ask
again.

## 3. Disconnect

Remove the app's access at https://www.dropbox.com/account/connected_apps, then ask Claude to switch
the source off.
