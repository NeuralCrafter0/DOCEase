/// "TEST DATA" markers for anything that leaves the app in dev mode (PDF
/// pages, PDF file name, shared text), so dev-build output can never pass
/// as a real medical record.
library;

import '../config/dev_mode.dart';

/// Printed on every PDF page and at the top of shared text in dev mode.
const kTestDataMarker = 'TEST DATA - NOT A MEDICAL RECORD';

/// Prefix for exported file names in dev mode.
const kTestDataFilePrefix = 'TEST_DATA_';

/// [text] with a first line saying it is test data when [testData] (dev
/// mode, `DevMode.of(context)`); otherwise [text] unchanged.
///
/// Wraps whatever builds the share text: today the inline message in
/// patient_detail_screen.dart, after #7 `VisitShareText.build(...)`.
///
/// Only in dev builds: without the define (kDevMode is a const false)
/// [testData] is ignored and the marker is compiled out.
String markShareText(String text, {required bool testData}) =>
    kDevMode && testData ? '*$kTestDataMarker*\n$text' : text;
