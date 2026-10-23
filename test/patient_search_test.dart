// Regression tests for the patient search (QA feature pass F-SRCH-02,
// F-SRCH-04): phone numbers typed with spaces or +91, and family members
// hidden by an active search.
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/utils/patient_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('phoneMatchesQuery', () {
    const stored = '+919811111111';
    test('F-SRCH-02 matches a number typed with a space or +91', () {
      expect(phoneMatchesQuery(stored, '98111 11111'), isTrue);
      expect(phoneMatchesQuery(stored, '+91 9811111111'), isTrue);
      expect(phoneMatchesQuery(stored, '+91 98111-11111'), isTrue);
      expect(phoneMatchesQuery(stored, '098111 11111'), isTrue);
      expect(phoneMatchesQuery(stored, '9811111111'), isTrue);
      expect(phoneMatchesQuery(stored, '98111'), isTrue);
    });
    test('a number saved without +91 is found by a query with it', () {
      expect(phoneMatchesQuery('9811111111', '+91 98111 11111'), isTrue);
      expect(phoneMatchesQuery('98111 11111', '9811111111'), isTrue);
    });
    test('different numbers and plain words do not match', () {
      expect(phoneMatchesQuery(stored, '98222 22222'), isFalse);
      expect(phoneMatchesQuery(stored, '+91 9822222222'), isFalse);
      expect(phoneMatchesQuery(stored, 'rohan'), isFalse);
      expect(phoneMatchesQuery(stored, '   '), isFalse);
      expect(phoneMatchesQuery(stored, '+'), isFalse);
      expect(phoneMatchesQuery(stored, 'ravi 98'), isFalse);
    });
  });
}
