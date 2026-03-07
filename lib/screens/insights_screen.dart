import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/patient_provider.dart';

class InsightsScreen extends StatelessWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<PatientProvider>(context);
    final patients = provider.patients;
    
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

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(title: const Text('Clinical Insights', style: TextStyle(fontWeight: FontWeight.w900)), backgroundColor: Colors.transparent, elevation: 0),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildOverviewGrid(patients.length, totalVisits),
            const SizedBox(height: 32),
            const Text('Top Clinical Diagnoses', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF1E293B))),
            const SizedBox(height: 16),
            if (topDiag.isEmpty)
              _buildEmptyState('No diagnosis data yet. Start adding clinical notes to generate insights.')
            else
              ...topDiag.map((e) => _buildDiagRank(e.key, e.value, totalVisits)),
            const SizedBox(height: 32),
            const Text('Visit Distribution', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF1E293B))),
            const SizedBox(height: 16),
            _buildChartPlaceholder(),
          ],
        ),
      ),
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
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFE2E8F0))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: color, size: 20)),
            const SizedBox(height: 12),
            Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF1E293B))),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey.shade500)),
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
              Text(displayTitle, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF475569))),
              Text('$count cases', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF6366F1))),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: percent,
              backgroundColor: const Color(0xFFF1F5F9),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF6366F1)),
              minHeight: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChartPlaceholder() {
    return Container(
      height: 200, width: double.infinity,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFE2E8F0))),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_graph_rounded, size: 40, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            const Text('Visual Trends System Active', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 13)),
            const Text('Awaiting sufficient clinical data', style: TextStyle(color: Colors.grey, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(String message) {
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE2E8F0), style: BorderStyle.solid)),
      child: Column(
        children: [
          const Icon(Icons.medical_information_outlined, size: 40, color: Color(0xFFCBD5E1)),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
