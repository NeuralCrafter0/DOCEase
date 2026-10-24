// Stable test locators agreed with QA (acceptance plan section 6.4).
//
// Keys never change what is drawn and never reach screen readers. Ids in
// keys are the app's record UUIDs, never names or other patient data
// (security criterion S7). Copy can change freely without breaking tests.
import 'package:flutter/widgets.dart';

abstract final class QaKeys {
  // Home
  static const homeSearch = ValueKey<String>('home.search');
  static const homePatientList = ValueKey<String>('home.patientList');
  static ValueKey<String> homePatientTile(String id) => ValueKey<String>('home.patientTile.$id');
  static const homeRegisterPatient = ValueKey<String>('home.registerPatient');
  static const homeLoading = ValueKey<String>('home.loading');
  static const homeEmptyState = ValueKey<String>('home.emptyState');
  static const homeNoMatches = ValueKey<String>('home.noMatches');
  static const homeLoadFailed = ValueKey<String>('home.loadFailed');
  static const homeRefreshFailed = ValueKey<String>('home.refreshFailed');
  static const homeRetry = ValueKey<String>('home.retry');
  static const homeOpenProfile = ValueKey<String>('home.openProfile');
  static const homeOpenInsights = ValueKey<String>('home.openInsights');
  static const homeNavPatients = ValueKey<String>('home.nav.patients');
  static const homeNavProfile = ValueKey<String>('home.nav.profile');
  static const homeSignOut = ValueKey<String>('home.signOut');
  static const homeStatPatients = ValueKey<String>('home.stat.patients');
  static const homeStatVisits = ValueKey<String>('home.stat.visits');

  // Patient form
  static const patientFormName = ValueKey<String>('patientForm.name');
  static const patientFormAge = ValueKey<String>('patientForm.age');
  static const patientFormPhone = ValueKey<String>('patientForm.phone');
  static ValueKey<String> patientFormRelation(String value) => ValueKey<String>('patientForm.relation.$value');
  static ValueKey<String> patientFormGender(String value) => ValueKey<String>('patientForm.gender.$value');
  static const patientFormSave = ValueKey<String>('patientForm.save');
  static const patientFormDuplicate = ValueKey<String>('patientForm.duplicate');
  static const patientFormOpenExisting = ValueKey<String>('patientForm.duplicate.openExisting');
  static const patientFormRegisterAnyway = ValueKey<String>('patientForm.duplicate.registerAnyway');

  // Patient detail
  /// "Couldn't open this record" state (ROWSCOPE-UI-01).
  static const patientDetailUnreadable = ValueKey<String>('patientDetail.unreadable');
  static const patientDetailEdit = ValueKey<String>('patientDetail.edit');
  static const patientDetailDelete = ValueKey<String>('patientDetail.delete');
  static const patientDetailExportPdf = ValueKey<String>('patientDetail.exportPdf');
  static const patientDetailVitalsTrends = ValueKey<String>('patientDetail.vitalsTrends');
  static const patientDetailAddNote = ValueKey<String>('patientDetail.addNote');
  static const patientDetailCall = ValueKey<String>('patientDetail.call');
  static ValueKey<String> patientDetailFamilyChip(String id) => ValueKey<String>('patientDetail.familyChip.$id');
  static ValueKey<String> patientDetailTimelineCard(String id) => ValueKey<String>('patientDetail.timelineCard.$id');

  // Visit form
  static const visitFormDate = ValueKey<String>('visitForm.date');
  static ValueKey<String> visitFormType(String value) => ValueKey<String>('visitForm.type.$value');
  static const visitFormDiagnosis = ValueKey<String>('visitForm.diagnosis');
  static const visitFormSymptoms = ValueKey<String>('visitForm.symptoms');
  static const visitFormNotes = ValueKey<String>('visitForm.notes');
  static const visitFormBp = ValueKey<String>('visitForm.bp');
  static const visitFormPulse = ValueKey<String>('visitForm.pulse');
  static const visitFormTemp = ValueKey<String>('visitForm.temp');
  static const visitFormWeight = ValueKey<String>('visitForm.weight');
  static const visitFormSugar = ValueKey<String>('visitForm.sugar');
  static const visitFormPrescription = ValueKey<String>('visitForm.prescription');
  static const visitFormRepeatLast = ValueKey<String>('visitForm.repeatLast');
  static const visitFormCamera = ValueKey<String>('visitForm.camera');
  static const visitFormGallery = ValueKey<String>('visitForm.gallery');
  static ValueKey<String> visitFormPhotoTile(int i) => ValueKey<String>('visitForm.photoTile.$i');
  static ValueKey<String> visitFormRemovePhoto(int i) => ValueKey<String>('visitForm.removePhoto.$i');
  static const visitFormSave = ValueKey<String>('visitForm.save');

  // Visit sheet, confirm and share
  static const visitSheetEdit = ValueKey<String>('visitSheet.edit');
  static const visitSheetDelete = ValueKey<String>('visitSheet.delete');
  static const visitSheetShare = ValueKey<String>('visitSheet.share');
  static const confirmOk = ValueKey<String>('confirm.ok');
  static const confirmCancel = ValueKey<String>('confirm.cancel');
  static ValueKey<String> shareField(String name) => ValueKey<String>('share.field.$name');
  static const shareConfirm = ValueKey<String>('share.confirm');

  // PDF export confirm (shown before the system print or share dialog)
  static const pdfConfirmSheet = ValueKey<String>('pdfConfirm.sheet');
  static const pdfConfirmConfirm = ValueKey<String>('pdfConfirm.confirm');
  static const pdfConfirmCancel = ValueKey<String>('pdfConfirm.cancel');
}
