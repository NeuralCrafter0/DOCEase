/// "TEST DATA" markers for anything that leaves the app in dev mode (PDF
/// pages, PDF file name, shared text), so dev-build output can never pass
/// as a real medical record.
library;

/// Printed on every PDF page and at the top of shared text in dev mode.
const kTestDataMarker = 'TEST DATA - NOT A MEDICAL RECORD';

/// Prefix for exported file names in dev mode.
const kTestDataFilePrefix = 'TEST_DATA_';

/// [text] with a first line saying it is test data when [testData] (dev
/// mode, `DevMode.of(context)`); otherwise [text] unchanged.
///
/// Wraps whatever builds the share text: today the inline message in
/// patient_detail_screen.dart, after #7 `VisitShareText.build(...)`.
String markShareText(String text, {required bool testData}) =>
    testData ? '*$kTestDataMarker*\n$text' : text;
