// The ONE place QA tests name #10's strict-read API (final at #10 9a8d31b:
// DbReadException(reason), message "DbReadException(<reason>)";
// enum DbReadFailure { notOpen, readFailed, unreadableRow }). If the DB
// engineer renames anything, change only this file.
import 'package:docease/providers/local_database.dart';
import 'package:flutter_test/flutter_test.dart';

typedef QaReadException = DbReadException;
typedef QaReadFailure = DbReadFailure;

QaReadException qaReadException(QaReadFailure r) => DbReadException(r);
QaReadFailure qaReasonOf(QaReadException e) => e.reason;
String qaReadMessage(QaReadFailure r) => 'DbReadException(${r.name})';

Matcher throwsQaRead(QaReadFailure r) => throwsA(
    isA<QaReadException>().having((e) => e.reason, 'reason', r));
