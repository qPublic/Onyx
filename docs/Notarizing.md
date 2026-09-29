# Notarizing Onyx

Onyx is signed with a local certificate ("Onyx Local Signing"). That's fine on your own Mac, but anyone you share it
with gets a macOS warning and has to allow it by hand. Notarizing fixes that. It needs an Apple Developer Program
membership ($99 a year).

## One-time setup (you do this; it involves your Apple account)

1. Join the Apple Developer Program at developer.apple.com.
2. In Xcode › Settings › Accounts, or at developer.apple.com › Certificates, create a **Developer ID Application**
   certificate and install it in your login keychain.
3. Make an app-specific password at account.apple.com › Sign-In and Security › App-Specific Passwords.
4. Save the notarization login in your keychain (Terminal):

       xcrun notarytool store-credentials onyx-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID

   It asks for the app-specific password.
5. Add your Team ID to `Resources/Info.plist` as `OnyxTeamID`, and release one more version signed the old way.
   From that version on, Onyx's updater also accepts updates signed with your Developer ID. (Without this step,
   people would have to reinstall by hand after the switch.)

## Each release after that

    ONYX_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh dmg notarize

That signs Onyx with the hardened runtime and the permissions in `Resources/Onyx.entitlements`, sends the DMG to
Apple, waits for the result, and staples the ticket to it. Then release as usual.
