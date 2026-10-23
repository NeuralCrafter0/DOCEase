import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/vitals_series.dart';

const _primary = Color(0xFF6366F1);
const _secondary = Color(0xFF10B981);
const _grid = Color(0xFFF1F5F9);
const _muted = Color(0xFF94A3B8);

/// Line chart of one vital over time, x spaced by visit date.
/// BP draws systolic and diastolic with dashed 120 / 80 guides; the other
/// vitals draw one line over a light typical-range band.
class VitalTrendChart extends StatelessWidget {
  const VitalTrendChart({super.key, required this.series, this.height = 180});
  final VitalSeries series;
  final double height;

  double _x(DateTime d) => d.difference(series.points.first.date).inMinutes / (60 * 24);

  @override
  Widget build(BuildContext context) {
    final pts = series.points;
    if (pts.isEmpty) return SizedBox(height: height);
    final isBp = series.kind == VitalKind.bp;
    final xs = pts.map((p) => _x(p.date)).toList();
    var minX = xs.first, maxX = xs.last;
    if (maxX - minX < 1) {
      minX -= 1;
      maxX += 1;
    }

    final ys = <double>[
      for (final p in pts) ...[p.value, if (p.value2 != null) p.value2!],
      if (isBp) ...[bpTypical.systolic, bpTypical.diastolic],
      if (series.kind.typicalRange case final r?) ...[r.$1, r.$2],
    ];
    var minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
    final pad = math.max((maxY - minY) * 0.12, 1.0);
    minY = (minY - pad).floorToDouble();
    maxY = (maxY + pad).ceilToDouble();

    LineChartBarData line(List<FlSpot> spots, Color color) => LineChartBarData(
      spots: spots,
      color: color,
      barWidth: 3,
      isCurved: spots.length > 2,
      preventCurveOverShooting: true,
      isStrokeCapRound: true,
      dotData: FlDotData(
        getDotPainter: (spot, _, _, _) => FlDotCirclePainter(radius: 3.5, color: Colors.white, strokeWidth: 2.5, strokeColor: color),
      ),
      belowBarData: BarAreaData(show: !isBp, color: color.withValues(alpha: 0.08)),
    );

    final bars = <LineChartBarData>[
      line([for (var i = 0; i < pts.length; i++) FlSpot(xs[i], pts[i].value)], _primary),
      if (isBp) line([for (var i = 0; i < pts.length; i++) FlSpot(xs[i], pts[i].value2!)], _secondary),
    ];

    final dateFmt = DateFormat('dd MMM');
    final first = pts.first.date;
    Widget bottomTitle(double value, TitleMeta meta) {
      if (value != meta.min && value != meta.max) return const SizedBox.shrink();
      final d = first.add(Duration(minutes: (value * 24 * 60).round()));
      return SideTitleWidget(
        meta: meta,
        child: Text(
          dateFmt.format(d),
          style: const TextStyle(fontSize: 10, color: _muted, fontWeight: FontWeight.w600),
        ),
      );
    }

    final range = series.kind.typicalRange;
    return Semantics(
      container: true,
      label: _semanticsLabel(),
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: LineChart(
            LineChartData(
              minX: minX,
              maxX: maxX,
              minY: minY,
              maxY: maxY,
              lineBarsData: bars,
              gridData: FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => const FlLine(color: _grid, strokeWidth: 1)),
              borderData: FlBorderData(show: false),
              rangeAnnotations: RangeAnnotations(
                horizontalRangeAnnotations: [if (range != null) HorizontalRangeAnnotation(y1: range.$1, y2: range.$2, color: _secondary.withValues(alpha: 0.08))],
              ),
              extraLinesData: ExtraLinesData(
                horizontalLines: [
                  if (isBp) ...[
                    HorizontalLine(y: bpTypical.systolic, color: _primary.withValues(alpha: 0.35), strokeWidth: 1, dashArray: [4, 4]),
                    HorizontalLine(y: bpTypical.diastolic, color: _secondary.withValues(alpha: 0.35), strokeWidth: 1, dashArray: [4, 4]),
                  ],
                ],
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    getTitlesWidget: (v, meta) => (v == meta.min || v == meta.max)
                        ? const SizedBox.shrink()
                        : SideTitleWidget(
                            meta: meta,
                            child: Text(formatVital(v), style: const TextStyle(fontSize: 10, color: _muted)),
                          ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(showTitles: true, reservedSize: 26, interval: maxX - minX, getTitlesWidget: bottomTitle),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => const Color(0xFF1E293B),
                  getTooltipItems: (spots) => [
                    for (final s in spots)
                      LineTooltipItem(
                        s.barIndex == 0 ? '${dateFmt.format(pts[s.spotIndex].date)}\n${_valueText(pts[s.spotIndex])}' : '',
                        const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _valueText(VitalPoint p) => p.value2 != null ? '${formatVital(p.value)}/${formatVital(p.value2!)} ${series.kind.unit}' : '${formatVital(p.value)} ${series.kind.unit}';

  String _semanticsLabel() {
    final last = series.latest!;
    final n = series.points.length;
    return '${series.kind.label} trend, $n reading${n == 1 ? '' : 's'}, latest ${_valueText(last)} on ${DateFormat('dd MMM yyyy').format(last.date)}';
  }
}
