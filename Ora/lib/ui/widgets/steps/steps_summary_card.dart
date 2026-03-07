import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/services/steps_service.dart';
import '../glass/glass_card.dart';
import 'steps_mini_stat_chip.dart';
import 'steps_progress_ring.dart';

class StepsSummaryCard extends StatelessWidget {
  const StepsSummaryCard({
    super.key,
    required this.stepsService,
    required this.onOpenDetails,
    required this.onRequestAccess,
  });

  final StepsService stepsService;
  final VoidCallback onOpenDetails;
  final Future<void> Function() onRequestAccess;

  @override
  Widget build(BuildContext context) {
    final formatter = NumberFormat.decimalPattern();
    final compactFormatter = NumberFormat('0.#');

    double ratio(num actual, num target) {
      final safeTarget = target.toDouble();
      if (safeTarget <= 0) return 0;
      return (actual.toDouble() / safeTarget).clamp(0.0, 1.0);
    }

    return AnimatedBuilder(
      animation: stepsService,
      builder: (context, _) {
        final theme = Theme.of(context);
        final labelStyle = theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.66),
        );
        final isEnabled = stepsService.isPermissionGranted;

        final content = AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: isEnabled
              ? Column(
                  key: const ValueKey('steps-enabled'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        StepsProgressRing(
                          progress: stepsService.trackedProgressSegment,
                          secondaryProgress: stepsService.manualProgressSegment,
                          size: 46,
                          strokeWidth: 5.75,
                          child: Icon(
                            Icons.directions_walk_rounded,
                            size: 20,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              children: [
                                TextSpan(
                                  text: formatter.format(
                                    stepsService.totalStepsToday,
                                  ),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w800,
                                    color: theme.colorScheme.onSurface,
                                    height: 1,
                                  ),
                                ),
                                TextSpan(
                                  text: '  Steps Today',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.66),
                                    fontWeight: FontWeight.w600,
                                    height: 1.1,
                                  ),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(
                            Icons.chevron_right,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.8,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: StepsMiniStatChip(
                            icon: Icons.local_fire_department_rounded,
                            value: formatter.format(
                              stepsService.caloriesToday.round(),
                            ),
                            unit: 'kcal',
                            label: 'Calories',
                            progress: ratio(
                              stepsService.caloriesToday,
                              stepsService.goalEstimatedCalories,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: StepsMiniStatChip(
                            icon: Icons.route_rounded,
                            value: compactFormatter.format(
                              stepsService.distanceToday,
                            ),
                            unit: 'mi',
                            label: 'Distance',
                            progress: ratio(
                              stepsService.distanceToday,
                              stepsService.goalDistanceToday,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: StepsMiniStatChip(
                            icon: Icons.access_time_rounded,
                            value: formatter.format(
                              stepsService.durationTodayMinutes,
                            ),
                            unit: 'min',
                            label: 'Duration',
                            progress: ratio(
                              stepsService.durationTodayMinutes,
                              stepsService.goalDurationTodayMinutes,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                )
              : Row(
                  key: const ValueKey('steps-locked'),
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            theme.colorScheme.surface.withValues(alpha: 0.34),
                        border: Border.all(
                          color:
                              theme.colorScheme.outline.withValues(alpha: 0.18),
                        ),
                      ),
                      child: Icon(
                        Icons.directions_walk_rounded,
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.62),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            stepsService.lockedStateTitle,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            stepsService.lockedStateDescription,
                            style: labelStyle,
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: stepsService.isLoading ||
                              stepsService.isRequestingAccess
                          ? null
                          : () => onRequestAccess(),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(stepsService.lockedStateActionLabel),
                    ),
                  ],
                ),
        );

        return GestureDetector(
          onTap: isEnabled ? onOpenDetails : null,
          behavior: HitTestBehavior.opaque,
          child: GlassCard(
            padding: EdgeInsets.fromLTRB(14, 12, 14, isEnabled ? 14 : 12),
            child: content,
          ),
        );
      },
    );
  }
}
