import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hakbanghero/models/character_profile.dart';
import 'package:hakbanghero/models/hero_roster.dart';
import 'package:hakbanghero/screens/character/equipment_screen.dart';
import 'package:hakbanghero/widgets/block_ui.dart';
import 'package:hakbanghero/widgets/hero_rig.dart';

void main() {
  List<String> cards(WidgetTester tester) => tester.widgetList<HeroStill>(find.byType(HeroStill))
      .map((hero) => hero.heroId).toList();
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(
    padding: const EdgeInsets.all(16), child: child)));
  PressBlock tile(WidgetTester tester, String id) => tester.widget<PressBlock>(find.ancestor(
    of: find.text(heroById(id)!.name), matching: find.byType(PressBlock)).first);

  for (final count in [0, 1, 2, 3, 4, 6]) {
    testWidgets('$count available costumes show up to three cards with the appropriate control', (tester) async {
      await tester.pumpWidget(host(OwnedCostumeList(available: kHeroes.take(count).toList(),
        equipped: 'sprout', tier: BodyTier.normal, onEquip: (_) async => true)));
      expect(cards(tester).length, count.clamp(0, 3));
      expect(find.text('Show other costumes'), count > 3 ? findsOneWidget : findsNothing);
      expect(find.text('Hide other costumes'), findsNothing);
      if (count > 3) {
        await tester.tap(find.text('Show other costumes'));
        await tester.pump();
        expect(cards(tester).length, count);
        expect(find.text('Hide other costumes'), findsOneWidget);
        await tester.tap(find.text('Hide other costumes'));
        await tester.pump();
        expect(cards(tester), ['sprout', 'frog', 'penguin']);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('equipping a hidden costume preserves expansion, then collapse shows the latest three', (tester) async {
    var equipped = 'sprout';
    var usage = <String>[];
    var switching = false;
    late StateSetter update;
    await tester.pumpWidget(host(StatefulBuilder(builder: (_, setState) {
      update = setState;
      return OwnedCostumeList(available: kHeroes.take(6).toList(), equipped: equipped,
        usage: usage, switching: switching, tier: BodyTier.normal, onEquip: (hero) async {
          update(() { equipped = hero.id; usage = [hero.id, ...usage.where((id) => id != hero.id)]; });
          return true;
        });
    })));
    expect(tile(tester, 'sprout').onTap, isNull);
    expect(find.text('SLIME'), findsNothing);
    await tester.tap(find.text('Show other costumes'));
    await tester.pump();
    for (final id in ['frog', 'penguin', 'slime', 'frog']) {
      await tester.tap(find.text(heroById(id)!.name));
      await tester.pump();
      expect(find.text('Hide other costumes'), findsOneWidget);
      expect(cards(tester).length, 6);
      expect(tile(tester, id).color, Rb.gold);
      expect(tile(tester, id).onTap, isNull);
    }
    await tester.tap(find.text('Hide other costumes'));
    await tester.pump();
    expect(cards(tester), ['frog', 'slime', 'penguin']);
    await tester.tap(find.text('PENGUIN'));
    await tester.pump();
    expect(cards(tester), ['penguin', 'frog', 'slime']);
    expect(find.text('Show other costumes'), findsOneWidget);
    update(() => switching = true);
    await tester.pump();
    expect(tile(tester, 'frog').onTap, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pending or failed equip leaves order and expanded state intact', (tester) async {
    final completion = Completer<bool>();
    var switching = false;
    var attempts = 0;
    await tester.pumpWidget(host(StatefulBuilder(builder: (_, update) => OwnedCostumeList(
      available: kHeroes.take(4).toList(), equipped: 'sprout', tier: BodyTier.normal,
      switching: switching, onEquip: (_) async {
        attempts++;
        update(() => switching = true);
        final result = await completion.future;
        update(() => switching = false);
        return result;
      },
    ))));
    await tester.tap(find.text('Show other costumes'));
    await tester.pump();
    await tester.tap(find.text('SLIME'));
    await tester.pump();
    expect(tile(tester, 'frog').onTap, isNull);
    expect(cards(tester), ['sprout', 'frog', 'penguin', 'slime']);
    completion.complete(false);
    await tester.pump();
    expect(attempts, 1);
    expect(cards(tester), ['sprout', 'frog', 'penguin', 'slime']);
    expect(tile(tester, 'sprout').color, Rb.gold);
    expect(find.text('Hide other costumes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening uses saved order and starts collapsed', (tester) async {
    Widget list() => OwnedCostumeList(available: kHeroes.take(6).toList(), equipped: 'slime',
      usage: const ['slime', 'penguin', 'frog', 'sprout'], tier: BodyTier.normal,
      onEquip: (_) async => true);
    await tester.pumpWidget(host(list()));
    await tester.tap(find.text('Show other costumes'));
    await tester.pump();
    expect(cards(tester).length, 6);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(host(list()));
    expect(cards(tester), ['slime', 'penguin', 'frog']);
    expect(find.text('Show other costumes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling to gear items and back preserves expanded costumes', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(
      controller: scroll, cacheExtent: 0, children: [
        OwnedCostumeList(available: kHeroes.take(6).toList(), equipped: 'sprout',
          tier: BodyTier.normal, onEquip: (_) async => true),
        const SizedBox(height: 2000),
      ],
    ))));
    await tester.tap(find.text('Show other costumes'));
    await tester.pump();
    scroll.jumpTo(1000);
    await tester.pump();
    scroll.jumpTo(0);
    await tester.pump();
    expect(find.text('Hide other costumes'), findsOneWidget);
    expect(cards(tester).length, 6);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
