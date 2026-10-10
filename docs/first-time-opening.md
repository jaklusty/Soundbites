# Opening Soundbites for the first time

Soundbites is shared between friends and is not signed with an Apple or Microsoft developer
certificate, so each system shows a warning the first time. This is expected. The steps below
are the only ones needed, once.

## macOS (Sequoia 15 and Tahoe 26)

1. Open the `.dmg` and drag **Soundbites** into **Applications**.
2. Open Soundbites from Applications. A dialog says it "could not be verified" or "cannot be
   opened". Click **Done** (not Move to Bin).
3. Open **System Settings**, click **Privacy & Security** in the sidebar, and scroll down to the
   **Security** section.
4. Next to the line about Soundbites, click **Open Anyway**. The button is only there for about
   an hour after step 2; if it has gone, repeat step 2.
5. Enter your login password when asked. Soundbites opens and is remembered from now on.

Control-click then Open, the old trick, no longer works on macOS 15 and later.

If the message instead says Soundbites **"is damaged and can't be opened"**, that is a fault in
the build itself, not something to work around. Tell Jak which version you downloaded.

_Screenshots: to be added from a Mac that has never run the app (Phase 4)._

## Windows 10 and 11

1. Run **Soundbites-Setup-x.y.z.exe**.
2. A blue **"Windows protected your PC"** box appears (SmartScreen). Click **More info**, then
   **Run anyway**.
3. Follow the installer. Soundbites starts from the Start menu afterwards.

If the box has no **Run anyway** button, your PC has **Smart App Control** turned on
(Settings > Privacy & security > Windows Security > App & browser control). It blocks every
unsigned installer and cannot be overridden for one app. Tell Jak; the only fixes are turning
Smart App Control off (which Windows only allows by reinstalling) or a signed build.

Windows Defender may scan the first download for a few seconds before the installer opens.

_Screenshots: to be added from a clean Windows machine (Phase 4)._

## First launch, both systems

1. Soundbites asks for the folder where your sound library should live. Pick an empty folder on
   your own disk: **Movies** on a Mac, **Videos** or **Music** on Windows. Avoid iCloud Drive,
   Desktop and Documents on a Mac, and OneDrive on Windows, because synced folders can offload
   files while you are editing.
2. Say **Yes** to "Start a new library here?".
3. Soundbites downloads its two helper programs (yt-dlp and Deno, about 120 MB) and then starts
   fetching the feed. Clips arrive one at a time; the window stays usable. The feed line under the
   search box shows progress.
