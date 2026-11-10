import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:share_plus/share_plus.dart';

/// Additive, offline V2 module. It never drops or overwrites V1 tables.
class V2Store {
  V2Store._();
  static final instance = V2Store._();
  Database? _db;
  Future<Database> get db async {
    if (_db != null) return _db!;
    final d = await openDatabase(path.join(await getDatabasesPath(), 'bettaiah_pos.db'));
    await d.transaction((tx) async {
      await tx.execute('CREATE TABLE IF NOT EXISTS v2_tables(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, status TEXT NOT NULL DEFAULT \'available\')');
      await tx.execute('CREATE TABLE IF NOT EXISTS v2_orders(id INTEGER PRIMARY KEY AUTOINCREMENT, table_id INTEGER NOT NULL, status TEXT NOT NULL DEFAULT \'open\', created_at TEXT NOT NULL, closed_at TEXT)');
      await tx.execute('CREATE TABLE IF NOT EXISTS v2_order_items(id INTEGER PRIMARY KEY AUTOINCREMENT, order_id INTEGER NOT NULL, product_id INTEGER NOT NULL, product_name TEXT NOT NULL, quantity INTEGER NOT NULL, unit_cents INTEGER NOT NULL, kot_sent_qty INTEGER NOT NULL DEFAULT 0)');
      await tx.execute('CREATE TABLE IF NOT EXISTS v2_kots(id INTEGER PRIMARY KEY AUTOINCREMENT, order_id INTEGER NOT NULL, created_at TEXT NOT NULL, status TEXT NOT NULL DEFAULT \'pending\')');
      await tx.execute('CREATE TABLE IF NOT EXISTS v2_kot_items(id INTEGER PRIMARY KEY AUTOINCREMENT, kot_id INTEGER NOT NULL, product_name TEXT NOT NULL, quantity INTEGER NOT NULL)');
      await tx.execute('CREATE TABLE IF NOT EXISTS v2_stock_movements(id INTEGER PRIMARY KEY AUTOINCREMENT, product_id INTEGER NOT NULL, quantity_change INTEGER NOT NULL, reason TEXT NOT NULL, created_at TEXT NOT NULL)');
      for (var i = 1; i <= 20; i++) {
        await tx.rawInsert('INSERT OR IGNORE INTO v2_tables(name,status) VALUES(?,?)', ['T$i', 'available']);
      }
    });
    return _db = d;
  }
  Future<List<Map<String, Object?>>> tables() async => (await db).query('v2_tables', orderBy: 'id');
  Future<List<Map<String, Object?>>> products() async => (await db).query('products', where: 'active=1', orderBy: 'category,name');
  Future<List<Map<String, Object?>>> openOrders() async => (await db).query('v2_orders', where: "status='open'", orderBy: 'id DESC');
  Future<List<Map<String, Object?>>> orderItems(int orderId) async => (await db).query('v2_order_items', where: 'order_id=?', whereArgs: [orderId]);
  Future<List<Map<String, Object?>>> kots() async => (await db).query('v2_kots', orderBy: 'id DESC', limit: 100);
  Future<List<Map<String, Object?>>> kotItems(int kotId) async => (await db).query('v2_kot_items', where: 'kot_id=?', whereArgs: [kotId]);
  Future<int> getOrCreateOrder(int tableId) async {
    final d = await db;
    return d.transaction((tx) async {
      final existing = await tx.query('v2_orders', columns: ['id'], where: "table_id=? AND status='open'", whereArgs: [tableId], limit: 1);
      if (existing.isNotEmpty) return existing.first['id'] as int;
      final id = await tx.insert('v2_orders', {'table_id': tableId, 'created_at': DateTime.now().toIso8601String(), 'status': 'open'});
      await tx.update('v2_tables', {'status': 'occupied'}, where: 'id=?', whereArgs: [tableId]);
      return id;
    });
  }
  Future<void> addItem(int orderId, Map<String, Object?> product) async {
    final d = await db;
    await d.transaction((tx) async {
      final existing = await tx.query('v2_order_items', where: 'order_id=? AND product_id=?', whereArgs: [orderId, product['id']], limit: 1);
      if (existing.isEmpty) {
        await tx.insert('v2_order_items', {'order_id': orderId, 'product_id': product['id'], 'product_name': product['name'], 'unit_cents': product['price_cents'], 'quantity': 1, 'kot_sent_qty': 0});
      } else {
        await tx.rawUpdate('UPDATE v2_order_items SET quantity=quantity+1 WHERE id=?', [existing.first['id']]);
      }
    });
  }
  Future<int?> sendKot(int orderId) async {
    final d = await db;
    return d.transaction((tx) async {
      final items = await tx.query('v2_order_items', where: 'order_id=? AND quantity>kot_sent_qty', whereArgs: [orderId]);
      if (items.isEmpty) return null;
      final id = await tx.insert('v2_kots', {'order_id': orderId, 'created_at': DateTime.now().toIso8601String(), 'status': 'pending'});
      for (final item in items) {
        final unsent = (item['quantity'] as int) - (item['kot_sent_qty'] as int);
        await tx.insert('v2_kot_items', {'kot_id': id, 'product_name': item['product_name'], 'quantity': unsent});
        await tx.update('v2_order_items', {'kot_sent_qty': item['quantity']}, where: 'id=?', whereArgs: [item['id']]);
      }
      return id;
    });
  }
  Future<void> setKotStatus(int id, String status) async {
    if (!['pending', 'preparing', 'ready', 'served'].contains(status)) throw ArgumentError('Invalid KOT status');
    await (await db).update('v2_kots', {'status': status}, where: 'id=?', whereArgs: [id]);
  }
  Future<void> adjustStock(int productId, int delta, String reason) async {
    if (delta == 0 || reason.trim().isEmpty) throw ArgumentError('Enter quantity and reason');
    final d = await db;
    await d.transaction((tx) async {
      final rows = await tx.query('products', where: 'id=?', whereArgs: [productId]);
      if (rows.isEmpty) throw StateError('Product not found');
      final next = (rows.first['stock'] as int) + delta;
      if (next < 0) throw StateError('Insufficient stock');
      await tx.update('products', {'stock': next}, where: 'id=?', whereArgs: [productId]);
      await tx.insert('v2_stock_movements', {'product_id': productId, 'quantity_change': delta, 'reason': reason.trim(), 'created_at': DateTime.now().toIso8601String()});
    });
  }
  Future<Map<String, int>> salesSummary() async {
    final d = await db;
    final rows = await d.rawQuery('SELECT COUNT(*) AS count, COALESCE(SUM(total_cents),0) AS total, COALESCE(SUM(tax_cents),0) AS tax FROM sales');
    return {'count': rows.first['count'] as int, 'total': rows.first['total'] as int, 'tax': rows.first['tax'] as int};
  }
  Future<List<Map<String, Object?>>> paymentSummary() async => (await db).rawQuery('SELECT payment, COUNT(*) AS count, SUM(total_cents) AS total FROM sales GROUP BY payment ORDER BY total DESC');
  Future<List<Map<String, Object?>>> lowStock() async => (await db).query('products', where: 'active=1 AND track_stock=1 AND stock<=5', orderBy: 'stock ASC');
  Future<String> exportV2Json() async {
    final d = await db;
    final out = <String, Object?>{'format': 'bettaiah-pos-v2-extension', 'version': 1, 'created_at': DateTime.now().toIso8601String()};
    for (final name in ['v2_tables', 'v2_orders', 'v2_order_items', 'v2_kots', 'v2_kot_items', 'v2_stock_movements']) {
      out[name] = await d.query(name);
    }
    return const JsonEncoder.withIndent('  ').convert(out);
  }
}

String v2Money(int cents) => '₹${(cents / 100).toStringAsFixed(2)}';

class BettaiahV2Page extends StatefulWidget {
  const BettaiahV2Page({super.key});
  @override
  State<BettaiahV2Page> createState() => _BettaiahV2PageState();
}

class _BettaiahV2PageState extends State<BettaiahV2Page> {
  int tab = 0;
  bool busy = true;
  List<Map<String, Object?>> tables = [], products = [], orders = [], tickets = [], payments = [], low = [];
  Map<String, int> summary = {};
  @override
  void initState() { super.initState(); reload(); }
  Future<void> reload() async {
    try {
      final store = V2Store.instance;
      final values = await Future.wait([store.tables(), store.products(), store.openOrders(), store.kots(), store.paymentSummary(), store.lowStock()]);
      final s = await store.salesSummary();
      if (mounted) setState(() { tables = values[0]; products = values[1]; orders = values[2]; tickets = values[3]; payments = values[4]; low = values[5]; summary = s; busy = false; });
    } catch (e) { if (mounted) { setState(() => busy = false); notify('$e'); } }
  }
  void notify(String message) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message))); }
  Future<void> openTable(Map<String, Object?> table) async {
    final id = await V2Store.instance.getOrCreateOrder(table['id'] as int);
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => V2OrderPage(orderId: id, tableName: table['name'] as String)));
    await reload();
  }
  Future<void> changeStock(Map<String, Object?> product) async {
    final amount = TextEditingController(); final reason = TextEditingController(text: 'Manual adjustment');
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: Text('Adjust ${product['name']}'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(signed: true), decoration: const InputDecoration(labelText: 'Change (+10 or -3)')), TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason'))]), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save'))]));
    if (ok == true) { try { await V2Store.instance.adjustStock(product['id'] as int, int.parse(amount.text), reason.text); await reload(); } catch (e) { notify('$e'); } }
    amount.dispose(); reason.dispose();
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Bettaiah POS V2')), body: busy ? const Center(child: CircularProgressIndicator()) : IndexedStack(index: tab, children: [
    GridView.builder(padding: const EdgeInsets.all(12), itemCount: tables.length, gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.5), itemBuilder: (_, i) { final t = tables[i]; final occupied = t['status'] == 'occupied'; return Card(child: InkWell(onTap: () => openTable(t), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.table_restaurant, color: occupied ? Colors.orange : Colors.green), Text('${t['name']}', style: const TextStyle(fontWeight: FontWeight.bold)), Text('${t['status']}')] ))); }),
    ListView(children: [for (final k in tickets) ListTile(title: Text('KOT #${k['id']} · Order ${k['order_id']}'), subtitle: Text('${k['status']} · ${k['created_at']}'), trailing: PopupMenuButton<String>(onSelected: (s) async { await V2Store.instance.setKotStatus(k['id'] as int, s); await reload(); }, itemBuilder: (_) => [for (final s in ['pending', 'preparing', 'ready', 'served']) PopupMenuItem(value: s, child: Text(s))]), onTap: () async { final items = await V2Store.instance.kotItems(k['id'] as int); if (!context.mounted) return; showDialog<void>(context: context, builder: (ctx) => AlertDialog(title: Text('KOT #${k['id']}'), content: Column(mainAxisSize: MainAxisSize.min, children: [for (final x in items) Text('${x['quantity']} × ${x['product_name']}')]), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))])); })]),
    ListView(children: [const ListTile(title: Text('Stock adjustments'), subtitle: Text('Use signed quantities to add or remove stock')), for (final p in products) ListTile(title: Text('${p['name']}'), subtitle: Text('Stock: ${p['stock']} · Tracking: ${p['track_stock'] == 1 ? 'On' : 'Off'}'), trailing: const Icon(Icons.edit), onTap: () => changeStock(p))]),
    ListView(padding: const EdgeInsets.all(16), children: [Text('Recorded sales: ${summary['count'] ?? 0}', style: Theme.of(context).textTheme.titleLarge), Text('Revenue: ${v2Money(summary['total'] ?? 0)}'), Text('Recorded tax: ${v2Money(summary['tax'] ?? 0)}'), const Divider(), const Text('Payments', style: TextStyle(fontWeight: FontWeight.bold)), for (final p in payments) ListTile(title: Text('${p['payment']}'), subtitle: Text('${p['count']} sales'), trailing: Text(v2Money(p['total'] as int))), const Divider(), Text('Low stock (≤5): ${low.length}', style: const TextStyle(fontWeight: FontWeight.bold)), for (final p in low) ListTile(title: Text('${p['name']}'), trailing: Text('${p['stock']}')), const Divider(), OutlinedButton.icon(onPressed: () async { final json = await V2Store.instance.exportV2Json(); await SharePlus.instance.share(ShareParams(text: json, subject: 'Bettaiah POS V2 extension backup')); }, icon: const Icon(Icons.share), label: const Text('Share V2 extension data (JSON)'))]),
  ]), bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (i) => setState(() => tab = i), destinations: const [NavigationDestination(icon: Icon(Icons.table_restaurant), label: 'Tables'), NavigationDestination(icon: Icon(Icons.soup_kitchen), label: 'KOT'), NavigationDestination(icon: Icon(Icons.inventory), label: 'Stock'), NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Reports')]));
}

class V2OrderPage extends StatefulWidget {
  final int orderId;
  final String tableName;
  const V2OrderPage({super.key, required this.orderId, required this.tableName});
  @override State<V2OrderPage> createState() => _V2OrderPageState();
}
class _V2OrderPageState extends State<V2OrderPage> {
  List<Map<String, Object?>> items = [], products = [];
  bool busy = true;
  @override void initState() { super.initState(); reload(); }
  Future<void> reload() async { final p = await V2Store.instance.products(); final i = await V2Store.instance.orderItems(widget.orderId); if (mounted) setState(() { products = p; items = i; busy = false; }); }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text('${widget.tableName} · Order #${widget.orderId}')), body: busy ? const Center(child: CircularProgressIndicator()) : Column(children: [Expanded(child: ListView(children: [const ListTile(title: Text('Running order')), for (final i in items) ListTile(title: Text('${i['product_name']} × ${i['quantity']}'), subtitle: Text('KOT sent: ${i['kot_sent_qty']}'), trailing: Text(v2Money((i['quantity'] as int) * (i['unit_cents'] as int))))])), const Divider(), const Padding(padding: EdgeInsets.all(8), child: Text('Add products', style: TextStyle(fontWeight: FontWeight.bold))), Expanded(child: ListView.builder(itemCount: products.length, itemBuilder: (_, index) { final p = products[index]; return ListTile(title: Text('${p['name']}'), subtitle: Text(v2Money(p['price_cents'] as int)), trailing: const Icon(Icons.add_circle_outline), onTap: () async { await V2Store.instance.addItem(widget.orderId, p); await reload(); }); })), Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: items.isEmpty ? null : () async { final id = await V2Store.instance.sendKot(widget.orderId); if (!context.mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(id == null ? 'No new items to send' : 'KOT #$id saved offline'))); await reload(); }, icon: const Icon(Icons.receipt_long), label: const Text('Send new items to kitchen (KOT)'))))]));
}
