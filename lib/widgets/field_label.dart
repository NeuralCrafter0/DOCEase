import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Heading above a field group or selector. Read as a heading.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(children: [
        Expanded(child: Semantics(header: true, child: Text(text, style: context.type.titleSmall?.copyWith(color: context.ds.inkSecondary)))),
        ?trailing,
      ]),
    );
  }
}
