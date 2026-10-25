# Quick start: the Xcode project is included

`RecipeBox.xcodeproj` (next to the `RecipeBox/` and `ShareExtension/` folders)
already contains both targets, the embedded extension, the App Group
entitlements, deployment target 17.0, the camera/photo permission strings and
no bridging header. Open it, then only:

1. Select each target ▸ **Signing & Capabilities** ▸ choose your **Team**.
2. If your bundle ID is not `com.chadchurch.RecipeBox`, change it on both
   targets (the extension's must be the app's plus `.ShareExtension`), and
   change the App Group to `group.<your app bundle ID>` in both
   `.entitlements` files, in the App Groups box on both targets, and in
   `appGroupID` in `SharedInbox.swift`. All three must be identical.
3. Add your app icon to `Assets.xcassets ▸ AppIcon` (a blank one is included).

The rest of this file describes the manual steps the project already did, in
case you add the extension to a different project.

---

# Adding the Share Extension in Xcode (about 10 minutes)

The source is written; the Xcode target, capability and App Group have to be
created in Xcode itself. No Keychain sharing is needed: the extension never
touches your API key — it only hands the shared items to the app.

## 1. Create the extension target
1. **File ▸ New ▸ Target… ▸ iOS ▸ Share Extension ▸ Next.**
2. Product Name: `ShareExtension` (any name works). Language Swift.
   If asked to "Activate scheme", say **Cancel** (keep running the app scheme).
3. Xcode generates `ShareViewController.swift`, `MainInterface.storyboard`
   and an `Info.plist` in a new group. **Delete** the generated
   `ShareViewController.swift` and `MainInterface.storyboard` (Move to Trash),
   then drag in this project's `ShareExtension/ShareViewController.swift`
   with only the **ShareExtension** target ticked.

## 2. Share SharedInbox.swift with both targets
Select `RecipeBox/SharedInbox.swift` ▸ File inspector ▸ **Target Membership**
▸ tick both **RecipeBox** and **ShareExtension**.

## 3. Extension Info.plist
Open the ShareExtension target's `Info.plist` (as Source Code). Replace the
whole `NSExtension` entry with the one in `Info.plist.NSExtension.xml`.
In particular remove `NSExtensionMainStoryboard` — the replacement uses
`NSExtensionPrincipalClass` instead. The activation rule there allows up to
10 images, text, and one web link.

## 4. App Group (on BOTH targets)
For **RecipeBox** and again for **ShareExtension**:
**Signing & Capabilities ▸ + Capability ▸ App Groups ▸ +** and add the same
group, e.g. `group.com.yourname.RecipeBox` (use your bundle ID prefix).
Then open `SharedInbox.swift` and set `appGroupID` to exactly that string.

## 5. Deployment target
Set the ShareExtension's **iOS Deployment Target** to the same as the app (17.0).

## 6. Run and test
1. Run the **RecipeBox** scheme on a real device once.
2. In Photos (or Instagram: screenshot a caption first), tap **Share**, scroll
   the app row to **More** and enable **ShareExtension**/RecipeBox
   (and drag it up in Favorites if you like). The name shown is the
   extension target's *Display Name*; set `Bundle display name` in its
   Info.plist to "RecipeBox" if you want it to read that way.
3. Choose RecipeBox in the share sheet → "Saved to RecipeBox" → open the app.
   The shared images go straight into the join/mask/read flow; shared text
   is read directly.

## Instagram specifics
Instagram's own share sheet ("Send to…") lists Instagram contacts, not
extensions — RecipeBox cannot appear there. Use the system share sheet:
take screenshots of the caption (they appear in Photos), select them in
Photos, tap Share ▸ RecipeBox. Sharing an Instagram *link* is rejected with
a message, because a link can't be read without Instagram's login.

## If something fails
- **"Setup incomplete" in the share sheet:** the App Group is missing on one
  target, or `appGroupID` doesn't match.
- **RecipeBox is not in the share sheet:** run once, then More ▸ enable it;
  also check the Info.plist activation rule was replaced.
- **Nothing happens when opening the app:** items are imported only when the
  app is idle on its home screen (not mid-edit) and an API key is set for the
  chosen AI engine — otherwise they wait, and are picked up afterwards.
