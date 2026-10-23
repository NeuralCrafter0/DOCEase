import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/patient.dart';
import '../providers/patient_provider.dart';
import '../utils/vitals_series.dart';
import '../widgets/vital_trend_chart.dart';

/// Vitals trends for one patient, from the visits on this phone.
class VitalsTrendsScreen extends StatelessWidget {
  const VitalsTrendsScreen({super.key, required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context) {
    return Consumer<PatientProvider>(builder: (ctx, provider, _) {
      final matches = provider.patients.where((p) => p.id == patientId);
      final patient = matches.isEmpty ? null : matches.first;
      return Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        appBar: AppBar(
          title: Text(patient == null ? 'Vitals Trends' : '${patient.name} · Vitals', style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF1E293B))),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: patient == null
            ? const _Empty(icon: Icons.person_off_outlined, text: 'This patient is no longer on this phone.')
            : VitalsTrendsView(patient: patient),
      );
    });
  }
}

/// The trend cards for [patient]. Takes plain data, so it needs no provider.
class VitalsTrendsView extends StatelessWidget {
  const VitalsTrendsView({super.key, required this.patient});
  final Patient patient;

  @override
  Widget build(BuildContext context) {
    final all = [for (final k in VitalKind.values) vitalSeries(patient.history, k)];
    final shown = all.where((s) => s.points.isNotEmpty || s.unreadable > 0).toList();
    if (shown.isEmpty) {
      return const _Empty(
        icon: Icons.monitor_heart_outlined,
        text: 'No vitals recorded yet.\nAdd BP, pulse, temperature, weight or blood sugar on a clinical note to see trends here.',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [for (final s in shown) _TrendCard(series: s)],
    );
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.series});
  final VitalSeries series;

  String _v(VitalPoint p) => p.value2 != null ? '${formatVital(p.value)}/${formatVital(p.value2!)}' : formatVital(p.value);

  @override
  Widget build(BuildContext context) {
    final kind = series.kind;
    final latest = series.latest;
    final prev = series.previous;
    final n = series.points.length;
    return Container(
      key: ValueKey('trend-${kind.name}'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE2E8F0))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(kind.label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Color(0xFF1E293B))),
              if (latest != null)
                Text('Latest ${DateFormat('dd MMM yyyy').format(latest.date)}', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
            ]),
          ),
          if (latest != null)
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${_v(latest)} ${kind.unit}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF6366F1))),
              if (prev != null) _Change(latest: latest, previous: prev),
            ]),
        ]),
        if (n > 0) ...[
          const SizedBox(height: 16),
          VitalTrendChart(series: series),
          const SizedBox(height: 8),
          Text(
            n == 1
                ? '1 reading. Add another visit to see a trend.'
                : '$n readings · range ${formatVital(series.min!)}–${formatVital(series.max!)} ${kind.unit}',
            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
          ),
          if (kind == VitalKind.bp)
            const Text('Systolic (indigo) and diastolic (green); dashed lines at 120/80.', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          if (kind.typicalRange case final r?)
            Text('Shaded: typical adult range ${formatVital(r.$1)}–${formatVital(r.$2)} ${kind.unit}.', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
        ],
        if (series.unreadable > 0) ...[
          const SizedBox(height: 8),
          Text(
            series.unreadable == 1
                ? "1 entry couldn't be read as a number and isn't charted."
                : "${series.unreadable} entries couldn't be read as numbers and aren't charted.",
            style: const TextStyle(fontSize: 11, color: Color(0xFFB45309), fontWeight: FontWeight.w600),
          ),
        ],
      ]),
    );
  }
}

class _Change extends StatelessWidget {
  const _Change({required this.latest, required this.previous});
  final VitalPoint latest, previous;

  @override
  Widget build(BuildContext context) {
    final d = latest.value - previous.value;
    final which = latest.value2 != null ? ' systolic' : '';
    final text = d == 0 ? 'No$which change since last visit' : '${d > 0 ? '+' : '−'}${formatVital(d.abs())}$which since last visit';
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (d != 0) Icon(d > 0 ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 12, color: const Color(0xFF64748B)),
      Text(text, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
    ]);
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 44, color: const Color(0xFFCBD5E1)),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF64748B), fontSize: 13, fontWeight: FontWeight.w500)),
          ]),
        ),
      );
}
