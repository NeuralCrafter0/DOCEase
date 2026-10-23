// QA shim (not committed): the dev-mode draft's tripwires and local-only
// builders are #13's own, re-exported from test/backend/dev_mode_test.dart.
export '../backend/dev_mode_test.dart'
    show hits, TripAuth, TripFirestore, TripStorage, TripHelper, SettingsDb, VisitDb,
        LocalSessionDb, localPatients, localDoctor, localMedicines;
