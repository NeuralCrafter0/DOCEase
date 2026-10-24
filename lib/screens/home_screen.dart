import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import '../providers/patient_provider.dart';
import '../providers/doctor_provider.dart';
import 'add_patient_screen.dart';
import 'patient_detail_screen.dart';
import 'doctor_profile_screen.dart';
import 'insights_screen.dart';
import '../widgets/stat_card.dart';
import '../widgets/patient_load_failed_view.dart';
import '../utils/patient_load.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<DoctorProvider>(context, listen: false).fetchDoctorProfile();
      Provider.of<PatientProvider>(context, listen: false).fetchAndSetPatients();
    });
  }

  @override
  Widget build(BuildContext context) {
    final doctor = Provider.of<DoctorProvider>(context).currentDoctor;
    final patientProvider = Provider.of<PatientProvider>(context);

    // Calculate Today's Stats
    final now = DateTime.now();
    int todayPatients = 0;
    int todayVisits = 0;
    
    for (var p in patientProvider.patients) {
      bool seenToday = false;
      for (var r in p.history) {
        if (r.date.year == now.year && r.date.month == now.month && r.date.day == now.day) {
          todayVisits++;
          seenToday = true;
        }
      }
      if (seenToday) todayPatients++;
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      drawer: _buildProfessionalDrawer(context, doctor),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            expandedHeight: 120, floating: true, pinned: true, elevation: 0,
            backgroundColor: const Color(0xFFF8FAFC).withValues(alpha: 0.8),
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.only(left: 60, bottom: 16),
              title: const Text('DOCEase', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: Color(0xFF1E293B))),
            ),
            actions: [
              if (patientProvider.isSyncing) const Center(child: Padding(padding: EdgeInsets.only(right: 16), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))),
              _buildTopAvatar(doctor),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Daily Pulse', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF1E293B))),
                const SizedBox(height: 12),
                _buildDailyStats(todayPatients, todayVisits, unknown: PatientLoad.failed(patientProvider) && patientProvider.patients.isEmpty),
                const SizedBox(height: 24),
                _buildProfessionalSearchBar(context),
                const SizedBox(height: 16),
              ]),
            ),
          ),
          // A failed reload keeps the last list: show it read-only under a banner.
          if (PatientLoad.failed(patientProvider) && patientProvider.patients.isNotEmpty)
            SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: PatientRefreshFailedBanner(onRetry: () => PatientLoad.reload(patientProvider)))),
          _buildPatientList(patientProvider),
          const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
        ],
      ),
      // Registering is refused while the list failed to load (and would risk duplicates).
      floatingActionButton: PatientLoad.readOnly(patientProvider) ? null : FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1E293B), foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: const Icon(Icons.person_add_alt_1_outlined), label: const Text('Register Patient'),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (ctx) => const AddPatientScreen())),
      ),
    );
  }

  Widget _buildTopAvatar(dynamic doctor) {
    return Padding(
      padding: const EdgeInsets.only(right: 16.0),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (ctx) => const DoctorProfileScreen())),
        child: CircleAvatar(
          radius: 18, backgroundColor: const Color(0xFFEEF2FF),
          backgroundImage: (doctor?.profileImageUrl != null && doctor!.profileImageUrl!.isNotEmpty) ? NetworkImage(doctor.profileImageUrl!) : null,
          child: (doctor?.profileImageUrl == null || doctor!.profileImageUrl!.isEmpty) ? const Icon(Icons.account_circle_outlined, color: Color(0xFF6366F1), size: 24) : null,
        ),
      ),
    );
  }

  Widget _buildDailyStats(int pts, int vsts, {bool unknown = false}) {
    return Row(children: [
      _buildDailyCard('Today Patients', unknown ? '—' : pts.toString(), Icons.person_outline, const Color(0xFF6366F1)),
      const SizedBox(width: 12),
      _buildDailyCard('Today Visits', unknown ? '—' : vsts.toString(), Icons.history_edu_outlined, const Color(0xFF10B981)),
    ]);
  }

  Widget _buildDailyCard(String label, String value, IconData icon, Color color) {
    return Expanded(child: StatCard(label: label, value: value, icon: icon, color: color));
  }

  Widget _buildProfessionalSearchBar(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.7), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE2E8F0))),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Search patients...', prefixIcon: Icon(Icons.search_rounded, color: Color(0xFF6366F1)), border: InputBorder.none, contentPadding: EdgeInsets.symmetric(vertical: 18)),
            onChanged: (v) => Provider.of<PatientProvider>(context, listen: false).setSearchQuery(v),
          ),
        ),
      ),
    );
  }

  Widget _buildPatientList(PatientProvider provider) {
    final patients = provider.patients;
    // Never show the empty state after a failed read: it leads to duplicate registrations.
    if (patients.isEmpty && PatientLoad.failed(provider)) return SliverFillRemaining(hasScrollBody: false, child: PatientLoadFailedView(onRetry: () => PatientLoad.reload(provider)));
    if (patients.isEmpty) return const SliverFillRemaining(child: Center(child: Text('No Clinical Records')));
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (ctx, i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
          child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFF1F5F9))),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(14)), child: const Icon(Icons.person_search_outlined, color: Color(0xFF6366F1))),
              title: Text(patients[i].name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Color(0xFF1E293B))),
              subtitle: Text(patients[i].phone, style: const TextStyle(color: Color(0xFF64748B), fontSize: 13)),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (ctx) => PatientDetailScreen(patientId: patients[i].id))),
            ),
          ),
        ),
        childCount: patients.length,
      ),
    );
  }

  Widget _buildProfessionalDrawer(BuildContext context, dynamic doctor) {
    return Drawer(
      backgroundColor: Colors.white,
      child: Column(children: [
        Container(
          padding: const EdgeInsets.fromLTRB(24, 60, 24, 32),
          decoration: const BoxDecoration(color: Color(0xFF1E293B), borderRadius: BorderRadius.only(bottomRight: Radius.circular(32))),
          child: Row(children: [
            CircleAvatar(radius: 35, backgroundColor: Colors.white24, backgroundImage: (doctor?.profileImageUrl != null && doctor!.profileImageUrl!.isNotEmpty) ? NetworkImage(doctor.profileImageUrl!) : null, child: (doctor?.profileImageUrl == null || doctor!.profileImageUrl!.isEmpty) ? const Icon(Icons.medical_services_outlined, color: Colors.white, size: 32) : null),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(doctor != null ? "${doctor.title} ${doctor.name}" : 'Doctor Name', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
              Text(doctor?.specialty ?? 'Clinical Specialist', style: TextStyle(color: Colors.white70, fontSize: 12)),
            ])),
          ]),
        ),
        const SizedBox(height: 16),
        _buildDrawerItem(Icons.dashboard_outlined, 'Clinical Dashboard', () => Navigator.pop(context)),
        _buildDrawerItem(Icons.analytics_outlined, 'Clinical Insights', () { Navigator.pop(context); Navigator.of(context).push(MaterialPageRoute(builder: (ctx) => const InsightsScreen())); }),
        _buildDrawerItem(Icons.badge_outlined, 'Professional Profile', () { Navigator.pop(context); Navigator.of(context).push(MaterialPageRoute(builder: (ctx) => const DoctorProfileScreen())); }),
        const Spacer(),
        Padding(padding: const EdgeInsets.all(24.0), child: ListTile(onTap: () => FirebaseAuth.instance.signOut(), leading: const Icon(Icons.logout_rounded, color: Colors.redAccent), title: const Text('Sign Out', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), tileColor: Colors.red.withOpacity(0.05))),
      ]),
    );
  }

  Widget _buildDrawerItem(IconData icon, String title, VoidCallback onTap) {
    return ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4), leading: Icon(icon, color: const Color(0xFF475569), size: 22), title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF1E293B), fontSize: 15)), onTap: onTap);
  }
}
