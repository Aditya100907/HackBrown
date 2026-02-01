# CodeSign Failed – Troubleshooting

## errSecInternalComponent when signing PresagePreprocessing.framework

If you see:
```text
HackBrown.app/Frameworks/PresagePreprocessing.framework: errSecInternalComponent
Command CodeSign failed with a nonzero exit code
```

That means **codesign couldn’t use the signing identity** (keychain/security), usually when signing the SmartSpectra embedded framework. Try these in order:

1. **Unlock the keychain**  
   Open **Keychain Access** → select **login** → ensure it’s unlocked (no lock icon). If it’s locked, unlock it and try building again.

2. **Clean DerivedData and rebuild**  
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData/HackBrown-*
   ```  
   Then in Xcode: **Product → Clean Build Folder** (⇧⌘K), then **Build** (⌘B).

3. **Allow keychain access for the signing identity**  
   In **Keychain Access**, search for **“Apple Development”** or **“kothari.aditya09”** → double‑click the certificate → **Access Control** tab → choose **“Allow all applications to access this item”** → Save. Then build again.

4. **Remove bad provisioning profile**  
   If the profile `584aefaf-855a-44df-8638-ceec10296ee8` was previously reported as invalid, delete it and let Xcode recreate it:  
   ```bash
   rm -f ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/584aefaf-855a-44df-8638-ceec10296ee8.mobileprovision
   ```  
   Reopen Xcode, **Signing & Capabilities** → toggle **Automatically manage signing** off/on or change Team and back, then build.

---

## What the build log showed (invalid profiles)

When building, Xcode reported **invalid provisioning profiles**:

- **DVTProvisioningProfileManager: Failed to load profile**  
  `Profile is missing the required UUID property.`

Affected profiles (on this machine):

- `~/Library/Developer/Xcode/UserData/Provisioning Profiles/1269abe6-1ee4-4e10-8d6e-909e3cd9e2e2.mobileprovision`
- `~/Library/Developer/Xcode/UserData/Provisioning Profiles/584aefaf-855a-44df-8638-ceec10296ee8.mobileprovision`

Corrupted or outdated profiles like this often lead to: **Command CodeSign failed with a nonzero exit code**.

---

## Fix: Remove bad profiles and refresh

1. **Quit Xcode.**

2. **Delete the bad provisioning profiles** (in Finder or Terminal):
   ```bash
   rm -f ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/1269abe6-1ee4-4e10-8d6e-909e3cd9e2e2.mobileprovision
   rm -f ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/584aefaf-855a-44df-8638-ceec10296ee8.mobileprovision
   ```
   Or open the folder and delete any `.mobileprovision` files that look old or that Xcode has complained about:
   ```bash
   open ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/
   ```

3. **Reopen Xcode**, open the HackBrown project, select the **HackBrown** target → **Signing & Capabilities**.

4. **Refresh signing**: turn **Automatically manage signing** off and back on, or change the **Team** and change it back. Let Xcode download/create new profiles.

5. **Clean and build**: Product → Clean Build Folder (⇧⌘K), then build (⌘B).

---

## How to see the exact CodeSign error in Xcode

1. **Report navigator**: ⌘9 → select the failed build.
2. Click the **error** line (“Command CodeSign failed with a nonzero exit code”).
3. In the log on the right, expand the **CodeSign** step and read the **full command and stderr** (often “profile doesn’t include …”, “identity not found”, or “resource fork …”).
4. Or: **View → Navigators → Show Report Navigator**, then open the latest build and search the log for `codesign` or `CodeSign`.

---

## Other common CodeSign causes

| Cause | What to do |
|-------|------------|
| Wrong or no team | Signing & Capabilities → pick the correct **Team** for this Mac/Apple ID. |
| Bundle ID not on team | Use a bundle ID already registered for that team (e.g. `com.hackbrown.HackBrown`) or register it in the developer portal. |
| Certificate missing/expired | Xcode → Settings → Accounts → [Your Apple ID] → Manage Certificates; fix or create “Apple Development”. |
| Entitlements not in profile | Remove extra capabilities from the `.entitlements` file or add them in the developer portal for the App ID. |
