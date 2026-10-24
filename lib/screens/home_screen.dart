import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../config/dev_mode.dart';
import '../models/doctor.dart';
import '../models/patient.dart';
import '../providers/doctor_provider.dart';
import '../providers/patient_provider.dart';
import '../services/session_controller.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';
import '../ui/formatters.dart';
import '../ui/qa_keys.dart';
import '../utils/doctor_name.dart';
import '../utils/patient_load.dart';
import '../utils/visit_order.dart';
import '../widgets/avatar_image.dart';
import '../widgets/patient_load_failed_view.dart';
import '../widgets/stat_card.dart';
import 'add_patient_screen.dart';
import 'doctor_profile_screen.dart';
import 'insights_screen.dart';
import 'patient_detail_screen.dart';

enum _Sort { recent, name }

/// One row of the list, with its sort key worked out once per change.
class _Row {
  _Row(this.patient, this.latest);
  final Patient patient;
  final VisitRecord? latest;
}

/// Today's numbers, by calendar day in local time, over every patient
/// (never the search-filtered list).
class _Today {
  const _Today(this.patients, this.visits);
  final int patients;
  final int visits;
}

/// Home: the doctor's patient list. It is the root's `phase == ready`
/// branch, never pushed.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _search = TextEditingController();
  final _scaffold = GlobalKey<ScaffoldState>();
  PatientProvider? _provider;
  _Sort _sort = _Sort.recent;
  bool _fabExtended = true;

  // Worked out once per provider change, not in build().
  List<_Row> _rows = const [];
  Set<String> _visibleIds = const {};
  _Today _today = const _Today(0, 0);
  DateTime _computedOn = DateTime(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Provider.of<DoctorProvider>(context, listen: false).fetchDoctorProfile();
      final p = Provider.of<PatientProvider>(context, listen: false);
      // The query lives in the provider and outlives this screen. This
      // field starts empty, so the list must not stay filtered by text the
      // doctor can't see (contract 1.2).
      p.setSearchQuery('');
      p.fetchAndSetPatients();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Provider.of<PatientProvider>(context, listen: false);
    if (!identical(p, _provider)) {
      _provider?.removeListener(_recompute);
      _provider = p;
      p.addListener(_recompute);
      _recompute(rebuild: false);
    }
  }

  @override
  void dispose() {
    _provider?.removeListener(_recompute);
    _search.dispose();
    super.dispose();
  }

  void _recompute({bool rebuild = true}) {
    final p = _provider;
    if (p == null) return;
    final now = DateTime.now();
    final all = p.allPatients;
    final rows = [for (final x in all) _Row(x, x.history.latestVisit)];
    _sortRows(rows);
    var tp = 0, tv = 0;
    for (final x in all) {
      var seen = false;
      for (final r in x.history) {
        if (!r.dateInvalid && Fmt.sameDay(r.date.toLocal(), now)) {
          tv++;
          seen = true;
        }
      }
      if (seen) tp++;
    }
    _rows = rows;
    _visibleIds = {for (final x in p.patients) x.id};
    _today = _Today(tp, tv);
    _computedOn = now;
    if (rebuild && mounted) setState(() {});
  }

  void _sortRows(List<_Row> rows) {
    if (_sort == _Sort.name) {
      rows.sort((a, b) => a.patient.name.toLowerCase().compareTo(b.patient.name.toLowerCase()));
      return;
    }
    // Newest last visit first; patients without a (readable) visit after.
    rows.sort((a, b) {
      final ad = a.latest == null || a.latest!.dateInvalid ? null : a.latest!.date;
      final bd = b.latest == null || b.latest!.dateInvalid ? null : b.latest!.date;
      if (ad == null && bd == null) return a.patient.name.toLowerCase().compareTo(b.patient.name.toLowerCase());
      if (ad == null) return 1;
      if (bd == null) return -1;
      return bd.compareTo(ad);
    });
  }

  void _toggleSort() {
    setState(() {
      _sort = _sort == _Sort.recent ? _Sort.name : _Sort.recent;
      _sortRows(_rows);
    });
  }

  void _onQuery(String v) {
    setState(() {}); // clear button
    context.read<PatientProvider>().setSearchQuery(v);
  }

  void _clearQuery() {
    _search.clear();
    _onQuery('');
  }

  Future<void> _open(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PatientProvider>();
    final doctor = context.watch<DoctorProvider>().currentDoctor;
    final now = DateTime.now();
    if (!Fmt.sameDay(now, _computedOn)) _recompute(rebuild: false); // past midnight

    final width = MediaQuery.sizeOf(context).width;
    final wide = Layout.classOf(width) == WidthClass.expanded;
    final readOnly = PatientLoad.readOnly(provider);
    // While the first load runs, registering isn't offered as the main
    // action (HOME-STATE-01): the list may not be empty at all.
    final loading = PatientLoad.loading(provider) && _rows.isEmpty;
    // The empty state carries its own Register button; one is enough.
    final empty = _rows.isEmpty && !PatientLoad.failed(provider);

    final nav = _NavPanel(
      doctor: doctor,
      permanent: wide,
      onInsights: () => _open(const InsightsScreen()),
      onProfile: () => _open(const DoctorProfileScreen()),
    );

    final body = NotificationListener<UserScrollNotification>(
      onNotification: (n) {
        final extend = n.direction != ScrollDirection.reverse;
        if (n.direction != ScrollDirection.idle && extend != _fabExtended) setState(() => _fabExtended = extend);
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () => PatientLoad.reload(provider),
        child: _buildScroll(context, provider, doctor, now, wide: wide, readOnly: readOnly),
      ),
    );

    final fabExtended = _fabExtended && MediaQuery.textScalerOf(context).scale(1) < 1.3;
    return Scaffold(
      key: _scaffold,
      drawer: wide ? null : Drawer(child: nav),
      body: wide
          ? Row(children: [
              SizedBox(width: Layout.sidebarWidth, child: Material(color: context.ds.surface, child: nav)),
              VerticalDivider(width: 1, color: context.ds.line),
              Expanded(child: body),
            ])
          : body,
      // Registering is refused while the list failed to load (and would
      // risk duplicates).
      floatingActionButton: readOnly || loading || empty
          ? null
          : FloatingActionButton.extended(
              key: QaKeys.homeRegisterPatient,
              // Icon-only once scrolled, and always at large text sizes,
              // where the wide label would cover the list. Static label only.
              tooltip: fabExtended ? null : 'Register patient',
              isExtended: fabExtended,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Register patient'),
              onPressed: () => _open(const AddPatientScreen()),
            ),
    );
  }

  Widget _buildScroll(BuildContext context, PatientProvider provider, Doctor? doctor, DateTime now,
      {required bool wide, required bool readOnly}) {
    final c = context.ds;
    final width = MediaQuery.sizeOf(context).width - (wide ? Layout.sidebarWidth + 1 : 0);
    final gutter = Layout.gutterFor(width);
    final side = ((width - Layout.contentMax) / 2).clamp(gutter, double.infinity);
    final pad = EdgeInsets.symmetric(horizontal: side);

    final failed = PatientLoad.failed(provider);
    final hasAny = _rows.isNotEmpty;
    final visible = [for (final r in _rows) if (_visibleIds.contains(r.patient.id)) r];
    final loading = PatientLoad.loading(provider) && !hasAny;
    final unknown = (failed || loading) && !hasAny;
    final searching = _search.text.trim().isNotEmpty;

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverAppBar(
          pinned: true,
          automaticallyImplyLeading: false,
          leading: wide
              ? null
              : IconButton(
                  tooltip: 'Open menu',
                  icon: const Icon(Icons.menu_rounded),
                  onPressed: () => _scaffold.currentState?.openDrawer(),
                ),
          titleSpacing: wide ? side : 0,
          // The sidebar shows the brand on wide screens.
          title: wide ? null : const _BrandTitle(),
          actions: [
            if (provider.isSyncing)
              Padding(
                padding: const EdgeInsets.only(right: Space.sm),
                child: Semantics(
                  label: 'Syncing',
                  child: const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              ),
            Padding(
              padding: EdgeInsets.only(right: wide ? side - Space.sm : Space.sm),
              child: _ProfileButton(doctor: doctor, onTap: () => _open(const DoctorProfileScreen())),
            ),
          ],
        ),
        SliverPadding(
          padding: pad.copyWith(top: Space.sm),
          sliver: SliverToBoxAdapter(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Fmt.today(now), style: context.type.labelLarge?.copyWith(color: c.inkMuted)),
              const SizedBox(height: Space.xxs),
              Semantics(
                header: true,
                child: Text(
                  [Fmt.greeting(now), ?doctorDisplayName(doctor)].join(', '),
                  style: context.type.headlineMedium,
                ),
              ),
              const SizedBox(height: Space.xl),
              _TodayStats(today: _today, unknown: unknown),
              const SizedBox(height: Space.xl),
            ]),
          ),
        ),
        SliverPersistentHeader(
          pinned: true,
          delegate: _SearchHeader(
            padding: pad,
            textScaler: MediaQuery.textScalerOf(context),
            child: _SearchField(controller: _search, onChanged: _onQuery, onClear: _clearQuery),
          ),
        ),
        if (failed && hasAny)
          SliverPadding(
            padding: pad.copyWith(top: Space.sm, bottom: Space.sm),
            sliver: SliverToBoxAdapter(
              child: PatientRefreshFailedBanner(
                key: QaKeys.homeRefreshFailed,
                retryKey: QaKeys.homeRetry,
                onRetry: () => PatientLoad.reload(provider),
              ),
            ),
          ),
        if (hasAny && visible.isNotEmpty)
          SliverPadding(
            padding: pad.copyWith(top: Space.md, bottom: Space.sm),
            sliver: SliverToBoxAdapter(
              child: SectionHeader(
                title: searching ? 'Results' : 'Patients',
                count: searching ? '${visible.length} of ${_rows.length}' : '${_rows.length}',
                trailing: _SortButton(sort: _sort, onPressed: _toggleSort),
              ),
            ),
          ),
        ..._buildListOrState(context, provider, visible, pad, readOnly: readOnly, failed: failed, loading: loading, hasAny: hasAny, now: now),
        // Room for the floating button (56) and its margins, so it never
        // hides the last row.
        const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
      ],
    );
  }

  List<Widget> _buildListOrState(BuildContext context, PatientProvider provider, List<_Row> visible, EdgeInsets pad,
      {required bool readOnly, required bool failed, required bool loading, required bool hasAny, required DateTime now}) {
    // Never the empty state after a failed read: it leads to duplicates (S6).
    if (!hasAny && failed) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: PatientLoadFailedView(
            key: QaKeys.homeLoadFailed,
            retryKey: QaKeys.homeRetry,
            onRetry: () => PatientLoad.reload(provider),
          ),
        ),
      ];
    }
    if (loading) {
      return [
        SliverPadding(
          padding: pad.copyWith(top: Space.md),
          sliver: const SliverToBoxAdapter(child: _LoadingList(key: QaKeys.homeLoading)),
        ),
      ];
    }
    // Until the loading signal lands (G2) this also shows for a moment while
    // the first read runs, so it stays calm and offers nothing destructive.
    if (!hasAny) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StatusView(
            key: QaKeys.homeEmptyState,
            icon: Icons.groups_2_outlined,
            title: 'No patients yet',
            message: 'Register a patient to start their record: visits, vitals, prescriptions and photos in one place.',
            actions: [
              if (!readOnly)
                FilledButton.icon(
                  onPressed: () => _open(const AddPatientScreen()),
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 20),
                  label: const Text('Register patient'),
                ),
            ],
          ),
        ),
      ];
    }
    if (visible.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StatusView(
            key: QaKeys.homeNoMatches,
            compact: true,
            icon: Icons.search_off_rounded,
            tone: Tone.neutral,
            liveRegion: true,
            title: 'No matching patients',
            message: 'Search looks at names and phone numbers. Check the spelling or try part of the number.',
            actions: [OutlinedButton(onPressed: _clearQuery, child: const Text('Clear search'))],
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: pad,
        sliver: SliverList.separated(
          key: QaKeys.homePatientList,
          itemCount: visible.length,
          separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
          itemBuilder: (ctx, i) {
            final row = visible[i];
            return _PatientTile(
              key: QaKeys.homePatientTile(row.patient.id),
              patient: row.patient,
              latest: row.latest,
              now: now,
              onTap: () => _open(PatientDetailScreen(patientId: row.patient.id)),
            );
          },
        ),
      ),
    ];
  }
}

class _BrandTitle extends StatelessWidget {
  const _BrandTitle();

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ExcludeSemantics(
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(color: c.primary, borderRadius: BorderRadius.circular(9)),
          alignment: Alignment.center,
          child: Icon(Icons.monitor_heart_rounded, size: 18, color: c.onPrimary),
        ),
      ),
      const SizedBox(width: Space.sm + 2),
      Text('DOCEase', style: context.type.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3)),
    ]);
  }
}

class _ProfileButton extends StatelessWidget {
  const _ProfileButton({required this.doctor, required this.onTap});

  final Doctor? doctor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: QaKeys.homeOpenProfile,
      tooltip: 'Profile',
      onPressed: onTap,
      icon: _DoctorAvatar(doctor: doctor, size: 34),
    );
  }
}

/// The doctor's photo, or initials, or a neutral icon. Decorative.
class _DoctorAvatar extends StatelessWidget {
  const _DoctorAvatar({required this.doctor, required this.size});

  final Doctor? doctor;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    final image = avatarImageFor(doctor?.profileImageUrl);
    final name = doctor?.name.trim() ?? '';
    if (image != null) {
      return ExcludeSemantics(child: CircleAvatar(radius: size / 2, backgroundColor: c.sunken, backgroundImage: image));
    }
    if (name.isNotEmpty) return Monogram(id: doctor!.id, name: name.replaceFirst(RegExp(r'^dr\.?\s+', caseSensitive: false), ''), size: size);
    return ExcludeSemantics(
      child: CircleAvatar(
        radius: size / 2,
        backgroundColor: c.primaryTint,
        child: Icon(Icons.person_rounded, size: size * 0.58, color: c.onPrimaryTint),
      ),
    );
  }
}

class _TodayStats extends StatelessWidget {
  const _TodayStats({required this.today, required this.unknown});

  final _Today today;
  final bool unknown;

  @override
  Widget build(BuildContext context) {
    final a = StatCard(
      key: QaKeys.homeStatPatients,
      label: 'Patients today',
      value: unknown ? '—' : '${today.patients}',
      icon: Icons.person_outline_rounded,
    );
    final b = StatCard(
      key: QaKeys.homeStatVisits,
      label: 'Visits today',
      value: unknown ? '—' : '${today.visits}',
      icon: Icons.event_note_outlined,
      tone: Tone.info,
    );
    return LayoutBuilder(builder: (context, box) {
      // Side by side unless large text would squeeze the captions.
      final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
      if (box.maxWidth / scale < 300) {
        return Column(children: [a, const SizedBox(height: Space.sm), b]);
      }
      return IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: a), const SizedBox(width: Space.md), Expanded(child: b)]));
    });
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged, required this.onClear});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    final radius = BorderRadius.circular(Radii.pill);
    OutlineInputBorder b(Color color, [double w = 1]) => OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: color, width: w));
    return TextField(
      key: QaKeys.homeSearch,
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      // Patient names: no keyboard learning (security review C12).
      enableIMEPersonalizedLearning: false,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      style: context.type.bodyLarge,
      decoration: InputDecoration(
        hintText: 'Search by name or phone',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(tooltip: 'Clear search', icon: const Icon(Icons.close_rounded, size: 20), onPressed: onClear),
        fillColor: c.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md + 2),
        border: b(c.line),
        enabledBorder: b(c.line),
        focusedBorder: b(c.primary, 2),
      ),
    );
  }
}

/// Keeps the search field pinned under the app bar once the greeting has
/// scrolled away.
class _SearchHeader extends SliverPersistentHeaderDelegate {
  _SearchHeader({required this.child, required this.padding, required this.textScaler});

  final Widget child;
  final EdgeInsets padding;
  final TextScaler textScaler;

  double get _height => 50 + textScaler.scale(16) * 1.5 - 24 + Space.md * 2;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final c = context.ds;
    return Container(
      color: c.canvas,
      padding: padding.copyWith(top: Space.sm, bottom: Space.sm),
      alignment: Alignment.center,
      child: child,
    );
  }

  @override
  bool shouldRebuild(_SearchHeader old) => old.child != child || old.padding != padding || old.textScaler != textScaler;
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.sort, required this.onPressed});

  final _Sort sort;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final recent = sort == _Sort.recent;
    return Semantics(
      label: recent ? 'Sorted by last visit. Sort by name' : 'Sorted by name. Sort by last visit',
      button: true,
      excludeSemantics: true,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.swap_vert_rounded, size: 18),
        label: Text(recent ? 'Last visit' : 'Name A–Z'),
        style: TextButton.styleFrom(foregroundColor: context.ds.inkSecondary, textStyle: context.type.labelMedium),
      ),
    );
  }
}

String _lower(String rel) => rel == 'Yesterday' ? 'yesterday' : rel;

class _PatientTile extends StatelessWidget {
  const _PatientTile({super.key, required this.patient, required this.latest, required this.now, required this.onTap});

  final Patient patient;
  final VisitRecord? latest;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    final meta = Fmt.patientMeta(patient);
    final phone = Fmt.phone(patient.phone);
    final relation = patient.relation.trim();
    final v = latest;
    final seenToday = v != null && !v.dateInvalid && Fmt.daysAgo(v.date, now) == 0;
    final lastLine = v == null
        ? 'No visits yet'
        : seenToday
            ? 'Seen today'
            : v.dateInvalid
                ? 'Last visit: date unknown'
                : 'Last visit ${_lower(Fmt.relativeDay(v, now))}';
    final count = patient.history.length;

    return DsCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md + 2, Space.sm, Space.md + 2),
      child: Row(children: [
        Monogram(id: patient.id, name: patient.name),
        const SizedBox(width: Space.md + 2),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: Space.sm, runSpacing: Space.xxs, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(patient.name.trim().isEmpty ? 'Unnamed patient' : patient.name, style: context.type.titleMedium),
              if (relation.isNotEmpty && relation != 'Self') Tag(label: relation),
              if (patient.hasParseErrors) const Tag(label: 'Partly unreadable', tone: Tone.warn, icon: Icons.error_outline_rounded),
            ]),
            if (meta.isNotEmpty || phone.isNotEmpty) ...[
              const SizedBox(height: Space.xxs),
              Text([meta, phone].where((s) => s.isNotEmpty).join('  ·  '), style: AppText.tabular(context.type.bodyMedium)),
            ],
            const SizedBox(height: Space.xs),
            Row(children: [
              ExcludeSemantics(
                child: Icon(seenToday ? Icons.check_circle_rounded : Icons.history_rounded, size: 15, color: seenToday ? c.primary : c.inkMuted),
              ),
              const SizedBox(width: Space.xs),
              Flexible(
                child: Text(
                  count > 0 ? '$lastLine  ·  ${Fmt.visitsCount(count)}' : lastLine,
                  style: context.type.bodySmall?.copyWith(color: seenToday ? c.primary : c.inkMuted, fontWeight: seenToday ? FontWeight.w600 : null),
                ),
              ),
            ]),
          ]),
        ),
        ExcludeSemantics(child: Icon(Icons.chevron_right_rounded, color: c.inkMuted)),
      ]),
    );
  }
}

/// Drawer contents on phones; a permanent sidebar on wide screens.
class _NavPanel extends StatelessWidget {
  const _NavPanel({required this.doctor, required this.permanent, required this.onInsights, required this.onProfile});

  final Doctor? doctor;
  final bool permanent;
  final VoidCallback onInsights;
  final VoidCallback onProfile;

  void _go(BuildContext context, VoidCallback action) {
    if (!permanent) Navigator.of(context).pop(); // close the drawer first
    action();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    final name = doctorDisplayName(doctor);
    final sub = [doctor?.specialty.trim() ?? '', doctor?.clinicName.trim() ?? ''].where((s) => s.isNotEmpty).join(' · ');
    return SafeArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xl, Space.xl, Space.xl, Space.lg),
          child: const _BrandTitle(),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          child: DsCard(
            color: c.canvas,
            borderColor: c.canvas,
            onTap: () => _go(context, onProfile),
            padding: const EdgeInsets.all(Space.md),
            child: Row(children: [
              _DoctorAvatar(doctor: doctor, size: 44),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // "Your profile" when unknown: null can mean not set up
                  // or not loaded, so it never claims either (G5).
                  Text(name ?? 'Your profile', style: context.type.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (sub.isNotEmpty) Text(sub, style: context.type.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                ]),
              ),
            ]),
          ),
        ),
        const SizedBox(height: Space.lg),
        _NavItem(key: QaKeys.homeNavPatients, icon: Icons.groups_2_outlined, selectedIcon: Icons.groups_2_rounded, label: 'Patients', selected: true, onTap: () {
          if (!permanent) Navigator.of(context).pop();
        }),
        _NavItem(key: QaKeys.homeOpenInsights, icon: Icons.insights_outlined, selectedIcon: Icons.insights_rounded, label: 'Insights', onTap: () => _go(context, onInsights)),
        _NavItem(key: QaKeys.homeNavProfile, icon: Icons.badge_outlined, selectedIcon: Icons.badge_rounded, label: 'Profile', onTap: () => _go(context, onProfile)),
        const Spacer(),
        // Dev mode has no account to leave, so no sign-out (contract 1.5).
        if (!DevMode.of(context))
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.lg),
            child: _NavItem(
              key: QaKeys.homeSignOut,
              icon: Icons.logout_rounded,
              selectedIcon: Icons.logout_rounded,
              label: 'Sign out',
              danger: true,
              inset: false,
              onTap: () {
                if (!permanent) Navigator.of(context).pop();
                context.read<SessionController>().signOut();
              },
            ),
          ),
      ]),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.danger = false,
    this.inset = true,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool danger;
  final bool inset;

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    final fg = danger ? c.danger : (selected ? c.onPrimaryTint : c.ink);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset ? Space.md : 0, vertical: Space.xxs),
      child: Semantics(
        selected: selected,
        child: Material(
          color: selected ? c.primaryTint : c.surface.withValues(alpha: 0),
          borderRadius: Radii.control,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
                child: Row(children: [
                  Icon(selected ? selectedIcon : icon, color: danger ? c.danger : (selected ? c.onPrimaryTint : c.inkSecondary), size: 22),
                  const SizedBox(width: Space.lg),
                  Expanded(child: Text(label, style: context.type.labelLarge?.copyWith(color: fg))),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder rows while the first load runs. Static under reduced motion,
/// otherwise a slow, gentle pulse.
class _LoadingList extends StatefulWidget {
  const _LoadingList({super.key});

  @override
  State<_LoadingList> createState() => _LoadingListState();
}

class _LoadingListState extends State<_LoadingList> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _pulse.value = 0.5;
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    Widget bar(double w, double h) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(color: c.sunken, borderRadius: BorderRadius.circular(h / 2)),
        );
    return Semantics(
      liveRegion: true,
      label: 'Loading patients',
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.55, end: 1).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
          child: Column(children: [
            for (var i = 0; i < 5; i++) ...[
              DsCard(
                padding: const EdgeInsets.all(Space.lg),
                child: Row(children: [
                  Container(width: 44, height: 44, decoration: BoxDecoration(color: c.sunken, shape: BoxShape.circle)),
                  const SizedBox(width: Space.md + 2),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      FractionallySizedBox(widthFactor: [0.55, 0.42, 0.62, 0.48, 0.5][i], child: bar(double.infinity, 14)),
                      const SizedBox(height: Space.sm),
                      FractionallySizedBox(widthFactor: 0.75, child: bar(double.infinity, 10)),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: Space.sm),
            ],
          ]),
        ),
      ),
    );
  }
}
