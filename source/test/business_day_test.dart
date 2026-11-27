import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/core/business_day.dart';

void main() {
  String day(BusinessDay b, DateTime t) => BusinessDay.keyOf(b.dateOf(t));

  test('default 00:00-00:00 is exactly the old midnight-to-midnight day', () {
    const b = BusinessDay();
    expect(b.cutoff, 0);
    expect(day(b, DateTime(2026, 11, 23, 0, 0)), '2026-11-23');
    expect(day(b, DateTime(2026, 11, 22, 23, 59)), '2026-11-22');
    expect(b.rangeOf(DateTime(2026, 11, 23)), (DateTime(2026, 11, 23), DateTime(2026, 11, 24)));
  });

  test('night cafe 21:00-03:00: the whole night is one day, dated by its evening', () {
    final b = BusinessDay.fromSettings('21:00', '03:00');
    expect(b.cutoff, 12 * 60);
    expect(day(b, DateTime(2026, 11, 22, 21, 30)), '2026-11-22');
    expect(day(b, DateTime(2026, 11, 23, 2, 45)), '2026-11-22');
    expect(day(b, DateTime(2026, 11, 23, 11, 59)), '2026-11-22');
    expect(day(b, DateTime(2026, 11, 23, 12, 0)), '2026-11-23');
  });

  test('day cafe 09:00-21:00: late sales after midnight stay on the same day', () {
    final b = BusinessDay.fromSettings('09:00', '21:00');
    expect(b.cutoff, 3 * 60);
    expect(day(b, DateTime(2026, 11, 22, 9, 0)), '2026-11-22');
    expect(day(b, DateTime(2026, 11, 23, 0, 30)), '2026-11-22');
    expect(day(b, DateTime(2026, 11, 23, 3, 0)), '2026-11-23');
  });

  test('24 hours, day ends 06:00', () {
    final b = BusinessDay.fromSettings('06:00', '06:00');
    expect(b.allDay, isTrue);
    expect(day(b, DateTime(2026, 11, 23, 5, 59)), '2026-11-22');
    expect(day(b, DateTime(2026, 11, 23, 6, 0)), '2026-11-23');
    final (from, to) = b.rangeOf(DateTime(2026, 11, 22));
    expect(from, DateTime(2026, 11, 22, 6));
    expect(to, DateTime(2026, 11, 23, 6));
  });

  test('typical 08:00-02:00, month and year boundaries', () {
    final b = BusinessDay.fromSettings('08:00', '02:00');
    expect(b.cutoff, 5 * 60);
    expect(day(b, DateTime(2027, 1, 1, 1, 0)), '2026-12-31');
    expect(day(b, DateTime(2026, 3, 1, 4, 0)), '2026-02-28');
  });

  test('bad or missing settings fall back to midnight; keys round-trip', () {
    expect(BusinessDay.fromSettings('25:00', null).cutoff, 0);
    expect(BusinessDay.fromSettings('9:00', 'x').cutoff, 0);
    expect(BusinessDay.parseMinutes('23:59'), 23 * 60 + 59);
    expect(BusinessDay.formatMinutes(75), '01:15');
    expect(BusinessDay.parseKey('2026-11-05'), DateTime(2026, 11, 5));
    expect(BusinessDay.parseKey('2026-11-5'), isNull);
  });

  test('UTC instants are judged in local time', () {
    final b = BusinessDay.fromSettings('21:00', '03:00');
    final local = DateTime(2026, 11, 23, 1, 0);
    expect(day(b, local.toUtc()), day(b, local));
  });
}
