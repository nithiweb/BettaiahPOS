# Bettaiah POS V2 — Phase 1 patch

This is a **working-source patch**, not a compiled APK. It adds persistent restaurant orders, KOT tracking, stock adjustments and basic sales reports while leaving the V1 billing interface intact.

## Installation in your existing GitHub project

1. Create a new branch `feature/offline-pos-v2` from `main` in GitHub. Do not edit `main` directly.
2. Upload `lib/v2_module.dart` from this package to the `lib/` folder.
3. In `lib/main.dart`, add this import beside the other imports:

   `import 'v2_module.dart';`

4. In `settingsPage()` locate `return ListView(padding:const EdgeInsets.all(16),children:[` and insert the following as the **first** widget after `children:[`:

   `FilledButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const BettaiahV2Page())), icon: const Icon(Icons.upgrade), label: const Text('Open V2 Tables / KOT / Stock / Reports')),`

5. Commit to the V2 branch. Open Actions, choose the existing APK workflow, select the V2 branch and run it. Download the artifact only after the workflow succeeds.
6. Back up V1 data before installing any development APK. Use the same Android application ID to upgrade without uninstalling.

## Current features

- 20 persistent tables, occupied/available display.
- Running table orders stored in SQLite; adding products to an order.
- Delta-based KOT: only items not previously sent to kitchen are included in new tickets.
- Kitchen ticket status: pending, preparing, ready, served.
- Stock adjustment with nonnegative-stock validation and movement history.
- Sales totals, payment breakdown, low-stock list.
- Export V2 extension data as JSON text via Android share sheet.

## Important limitations / next phase

- This patch does **not** implement thermal hardware printing, full GST-compliant invoices, final table settlement, order cancellations, or merged V1+V2 backup/restore. Those require further development and hardware-specific validation.
- KOT is saved digitally; 'Send to kitchen' does not physically print.
- V2 extension backup is export-only. V1 backup does not include V2 tables. Do not assume the V1 Restore function restores V2 data.
- The V2 schema is additive (`CREATE TABLE IF NOT EXISTS`), not yet a formal database version migration. Future release should move schema creation to the database's `onUpgrade` callback and implement full backup/restore.
- No APK compilation was performed in this environment. Verify via GitHub Actions and test on a non-production device first.
