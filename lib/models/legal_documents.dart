class LegalDocument {
  final String title;
  final String version;
  final String text;
  const LegalDocument(this.title, this.version, this.text);
}

abstract final class LegalDocuments {
  // Supply the actual release date when preparing the release build.
  static const effectiveDate = String.fromEnvironment('LEGAL_RELEASE_DATE',
      defaultValue: 'November 15, 2026');

  static const terms = LegalDocument('Terms of Service', '1.0', '''
Who operates HakbangHero
HakbangHero is a fitness-tracking capstone project operated by PUP Biñan Campus, under the advisory of Prof. Michael Anjelo O. Miguel and Indaleen Quinsayas. For questions, contact Hakbanghero@gmail.com.

Who may use the app
HakbangHero is intended for adults aged 18 and above. By creating an account, you confirm that you are at least 18 years old.

Your account
You may register with an email and password or sign in with Google. Provide accurate information, protect access to your account, and do not use another person's account without permission.

Fitness tracking
The app uses the profile information and measurements you provide to calculate a BMI-based character form. With device location permission, it records run or walk routes, distance, speed, and timing. GPS readings and fitness estimates may be inaccurate. The app is not medical advice. Choose activities suitable for your circumstances, pay attention to your surroundings, and stop if you feel unwell.

Rewards and other players
XP, coins, character items, challenges, and rankings are game features governed by the app's existing calculations and eligibility checks. A completed activity may remain pending if it cannot be saved. Do not manipulate GPS readings, activity records, or rewards. Your public profile and progress may appear on leaderboards or player cards. Treat other players respectfully when using friends, chat, and duels; do not harass, impersonate, or send abusive messages. Blocking and reporting controls are available in chat.

Documents and device permissions
New accounts must agree to these Terms and acknowledge reading the Privacy Policy before completing onboarding. These choices do not grant device location access; the app requests that permission separately. Closing a document does not select its checkbox.

Availability and leaving the project
This is a capstone service. Availability and successful synchronization depend on the app, your device, your connection, and supporting services. You can use the Delete Account control in Settings. Deletion limitations and the project's data-retention deadline are explained in the Privacy Policy.

Changes
Each document identifies its version and effective date. Keep a copy of the version you accept. Contact Hakbanghero@gmail.com if you have questions about a change.
''');

  static const privacy = LegalDocument('Privacy Policy', '1.0', '''
Operator and contact
HakbangHero is operated by PUP Biñan Campus, under the advisory of Prof. Michael Anjelo O. Miguel and Indaleen Quinsayas, as a capstone project for adults aged 18 and above. For privacy questions or requests, email Hakbanghero@gmail.com.

Account information
Firebase Authentication handles email/password and Google sign-in. Google sign-in supplies account information such as your account identifier, email address, and display name. The app uses an account identifier and hero name to associate your profile, activity records, and game progress with your account. It also records the document versions you accept and a server timestamp.

Profile and BMI information
The app collects your selected gender, height, weight, and character choices. Height and weight are used to calculate a BMI-based character form; weekly check-ins record measurements and changes. Email, height, and weight are stored in an owner-only private document. Weight-check-in records are also owner-only. Your gender, character form and appearance, and game progress are part of your profile and may be visible to other signed-in players. A visible character form may reveal a broad BMI category.

Location and activity information
When you grant location permission and start tracking, the app uses location readings to calculate movement, route coordinates, distance, speed, pace, and activity timing. Saved activity records include route information, activity type, start/end times, duration, and earned XP and coins. These activity records are owner-only under the app's Firestore rules. Location permission is separate from agreeing to these documents and can be managed through your device or browser settings. Tracking in a browser can be interrupted when the screen locks or the tab is suspended.

Rewards, rankings, and social features
The app stores rewards, totals, quests, stage records, and related progression to provide its game features. Other signed-in players can view profile information and ranking progress. Friends features use friend codes, requests, friendships, online/idle/offline presence, and duel progress. Private chat stores messages between players. Reports can include the reported player, a reason, and recent messages for review by the project operators.

Storage and supporting services
Firebase Authentication and Cloud Firestore process account and app data; the web app is hosted with Firebase Hosting. The app and browser also keep local preferences, cached data, run checkpoints, and queued finished runs so an interrupted save can be retried. Map views request map tiles from OpenStreetMap. Those requests disclose ordinary connection information such as your IP address and the map area requested to the map provider. These supporting services handle information through their own systems. The app does not include a separate analytics or advertising SDK in its current implementation.

How long project data is kept
Identifiable project data will be deleted within 90 days after the capstone's final acceptance. This is the project's retention commitment; the app does not currently have an automatic scheduled purge. The project operators must carry out that cleanup. Contact Hakbanghero@gmail.com with questions about the deadline or your data.

Account deletion and its limitations
Settings includes a Delete Account control that asks you to confirm your identity. The current deletion flow attempts to remove your profile, login, activities, queued cloud runs, private measurements and consent record, weight history, friendships, and related account records. It is not a guarantee that all copies are removed: some cleanup steps can fail, sent chat messages remain in other players' chat histories, and reports or duel records may remain. Local caches and copies may also remain. Contact the privacy email to ask about remaining project-held information or to request access, correction, or deletion; this policy does not promise a response period or complete immediate erasure.

Your choices
New users separately agree to the Terms of Service and acknowledge reading this policy. You can read both documents before selecting either checkbox. Device permissions are requested separately. If you do not wish to provide required onboarding information or accept the documents, do not complete signup. No marketing consent is requested.
''');
}
