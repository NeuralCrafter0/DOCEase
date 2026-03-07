# ?? DOCEase - Project Memory Anchor (GEMINI.md)

## ?? Current Project Vision
A premium, high-security medical history tracker for doctors.
**Philosophy:** Instant-launch speed, "Liquid Glass" UI smoothness, and top-tier clinical data protection.

## ??? Technical Stack & Architecture
- **State:** Provider (PatientProvider, DoctorProvider, MedicineProvider).
- **Database:** `sqflite_sqlcipher` (AES-256 Encrypted). Current file: `docease_production_v1.db`.
- **Cloud:** Firebase Firestore & Storage (Syncing records & high-res attachments).
- **Security:** Biometric Lock (local_auth) with 1-min inactivity timer + Screenshot Blocking (FLAG_SECURE).

## ?? Design Standards (Strict Rules)
- **Zero Jitter:** Use shared-indicator logic for all tabs/selectors.
- **Physics:** Always use `BouncingScrollPhysics()` for all lists.
- **Visuals:** Material 3, Rounded (24px+), Slate & Indigo palette, Frosted Glass (BackdropFilter).
- **Clinical Alignment:** Symbols must be professional (medical icons only), never "childish."

## ? Feature Check-list (Already Active)
- Google Sign-In (Auto-account picker).
- Smart Search (Trimmed, continuous matching).
- Family Smart-Link (Relations & Family Network chips).
- Vitals Section (BP, Temp, Pulse, Weight).
- Repeat Last Visit (Auto-fill previous data).
- Branded PDF Export (Doctor details on letterhead).
- Locked Doctor Profile (Edit icon to unlock).

## ?? Next Steps
Reference the `CLINICAL_IDEAS/FUTURE_FEATURES.md` for the current roadmap.

---
**Note to Gemini:** Read this file at the start of every session to ensure feature continuity and adherence to the design philosophy. NEVER remove existing features when building new ones.
