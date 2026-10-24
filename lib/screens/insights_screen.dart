import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/patient.dart';
import '../providers/patient_provider.dart';
import '../utils/insights_stats.dart';

class InsightsScreen extends StatelessWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Whole practice, not the home-screen search results.
    final patients = Provider.of<PatientProvider>(context).allPatients;
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Clinical Insights', style: TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: InsightsView(patients: patients),
    );
  }
}

/// The insights body for [patients]. Plain data in, so it needs no provider;
/// [now] fixes "this month" for tests.
class InsightsView extends StatelessWidget {
  const InsightsView({super.key, required this.patients, this.now});
  final List<Patient> patients;
  final DateTime? now;

  static const _ink = Color(0xFF1E293B);
  static const _primary = Color(0xFF6366F1);
  static const _typeColors = [Color(0xFF6366F1), Color(0xFF10B981), Color(0xFFF59E0B), Color(0xFFEC4899), Color(0xFF0EA5E9), Color(0xFF94A3B8)];

  @override
  Widget build(BuildContext context) {
    // Calculate Stats
    int totalVisits = 0;
    Map<String, int> diagnosisFreq = {};
    for (var p in patients) {
      totalVisits += p.history.length;
      for (var r in p.history) {
        final diag = r.diagnosis.trim().toLowerCase();
        if (diag.isNotEmpty) diagnosisFreq[diag] = (diagnosisFreq[diag] ?? 0) + 1;
      }
    }

    final sortedDiag = diagnosisFreq.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final topDiag = sortedDiag.take(5).toList();

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildOverviewGrid(patients.length, totalVisits),
          const SizedBox(height: 32),
          const Text(
            'Top Clinical Diagnoses',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _ink),
          ),
          const SizedBox(height: 16),
          if (topDiag.isEmpty) _buildEmptyState('No diagnosis data yet. Start adding clinical notes to generate insights.') else ...topDiag.map((e) => _buildDiagRank(e.key, e.value, totalVisits)),
          const SizedBox(height: 32),
          const Text(
            'Visit Distribution',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _ink),
          ),
          const SizedBox(height: 16),
          if (totalVisits == 0)
            _buildEmptyState('No visits yet. Charts appear here once clinical notes are added.')
          else ...[
            _buildMonthlyCard(visitsPerMonth(patients, now ?? DateTime.now())),
            const SizedBox(height: 16),
            _buildTypeCard(visitTypeBreakdown(patients), totalVisits),
          ],
        ],
      ),
    );
  }

  Widget _card({required Key key, required List<Widget> children}) => Container(
    key: key,
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );

  Widget _cardTitle(String title, String subtitle) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: _ink),
      ),
      Text(
        subtitle,
        style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
      ),
    ],
  );

  Widget _buildMonthlyCard(List<MonthCount> months) {
    final inWindow = months.fold<int>(0, (a, m) => a + m.count);
    final peak = months.fold<int>(0, (a, m) => m.count > a ? m.count : a);
    final fmt = DateFormat('MMM');
    return _card(
      key: const ValueKey('insights-monthly'),
      children: [
        _cardTitle('Visits per month', 'Last ${months.length} months · $inWindow visit${inWindow == 1 ? '' : 's'}'),
        const SizedBox(height: 20),
        if (inWindow == 0)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('No visits in the last 6 months.', style: TextStyle(color: Color(0xFF64748B), fontSize: 13)),
            ),
          )
        else
          Semantics(
            container: true,
            label: 'Visits per month: ${months.map((m) => '${fmt.format(m.month)} ${m.count}').join(', ')}',
            child: ExcludeSemantics(
              child: SizedBox(
                height: 180,
                child: BarChart(
                  BarChartData(
                    maxY: (peak * 1.25).ceilToDouble().clamp(1, double.infinity),
                    alignment: BarChartAlignment.spaceAround,
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                    barTouchData: BarTouchData(
                      enabled: false,
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (_) => Colors.transparent,
                        tooltipPadding: EdgeInsets.zero,
                        tooltipMargin: 4,
                        getTooltipItem: (group, _, rod, _) => BarTooltipItem(rod.toY.toInt().toString(), const TextStyle(color: _ink, fontWeight: FontWeight.w800, fontSize: 11)),
                      ),
                    ),
                    titlesData: FlTitlesData(
                      leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 24,
                          getTitlesWidget: (v, meta) => SideTitleWidget(
                            meta: meta,
                            child: Text(
                              fmt.format(months[v.toInt()].month),
                              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8), fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ),
                    ),
                    barGroups: [
                      for (var i = 0; i < months.length; i++)
                        BarChartGroupData(
                          x: i,
                          showingTooltipIndicators: months[i].count > 0 ? const [0] : const [],
                          barRods: [
                            BarChartRodData(
                              toY: months[i].count.toDouble(),
                              width: 18,
                              color: i == months.length - 1 ? _primary : _primary.withValues(alpha: 0.45),
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTypeCard(List<TypeCount> types, int total) {
    String pct(int c) => '${(c * 100 / total).round()}%';
    Color colorAt(int i) => _typeColors[i < _typeColors.length ? i : _typeColors.length - 1];
    return _card(
      key: const ValueKey('insights-types'),
      children: [
        _cardTitle('Visit types', 'All $total visit${total == 1 ? '' : 's'} on this phone'),
        const SizedBox(height: 20),
        Row(
          children: [
            Semantics(
              container: true,
              label: 'Visit types: ${types.map((t) => '${t.type} ${t.count} (${pct(t.count)})').join(', ')}',
              child: ExcludeSemantics(
                child: SizedBox(
                  width: 120,
                  height: 120,
                  child: PieChart(
                    PieChartData(
                      centerSpaceRadius: 34,
                      sectionsSpace: 2,
                      startDegreeOffset: -90,
                      sections: [for (var i = 0; i < types.length; i++) PieChartSectionData(value: types[i].count.toDouble(), color: colorAt(i), radius: 22, showTitle: false)],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < types.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(color: colorAt(i), shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              types[i].type,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF475569)),
                            ),
                          ),
                          Text(
                            '${types[i].count} · ${pct(types[i].count)}',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: _ink),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildOverviewGrid(int patients, int visits) {
    return Row(
      children: [
        _buildSmallStatCard('Total Patients', patients.toString(), const Color(0xFF6366F1), Icons.groups_rounded),
        const SizedBox(width: 16),
        _buildSmallStatCard('All-Time Visits', visits.toString(), const Color(0xFF10B981), Icons.analytics_outlined),
      ],
    );
  }

  Widget _buildSmallStatCard(String label, String value, Color color, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: _ink),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiagRank(String title, int count, int total) {
    final double percent = total > 0 ? count / total : 0;
    // Capitalize first letter
    final String displayTitle = title.length > 1 ? '${title[0].toUpperCase()}${title.substring(1)}' : title.toUpperCase();

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                displayTitle,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF475569)),
              ),
              Text(
                '$count cases',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF6366F1)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(value: percent, backgroundColor: const Color(0xFFF1F5F9), valueColor: const AlwaysStoppedAnimation(Color(0xFF6366F1)), minHeight: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0), style: BorderStyle.solid),
      ),
      child: Column(
        children: [
          const Icon(Icons.medical_information_outlined, size: 40, color: Color(0xFFCBD5E1)),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
