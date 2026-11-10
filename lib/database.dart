import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class PosDb {
  PosDb._();
  static final PosDb instance = PosDb._();
  Database? _db;
  Future<Database> get db async => _db ??= await openDatabase(
    p.join(await getDatabasesPath(), 'bettaiah_pos.db'),
    version: 1,
    onCreate: (d, v) async {
      await d.execute('CREATE TABLE products(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, category TEXT NOT NULL, price_cents INTEGER NOT NULL, stock INTEGER NOT NULL DEFAULT 0, track_stock INTEGER NOT NULL DEFAULT 0, active INTEGER NOT NULL DEFAULT 1)');
      await d.execute('CREATE TABLE sales(id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL, mode TEXT NOT NULL, table_no TEXT, subtotal_cents INTEGER NOT NULL, discount_cents INTEGER NOT NULL, tax_cents INTEGER NOT NULL, total_cents INTEGER NOT NULL, payment TEXT NOT NULL)');
      await d.execute('CREATE TABLE sale_items(id INTEGER PRIMARY KEY AUTOINCREMENT, sale_id INTEGER NOT NULL, product_id INTEGER, product_name TEXT NOT NULL, quantity INTEGER NOT NULL, unit_cents INTEGER NOT NULL, FOREIGN KEY(sale_id) REFERENCES sales(id))');
      await d.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      await d.insert('settings', {'key':'tax_percent','value':'0'});
      await d.insert('settings', {'key':'shop_name','value':'Bettaiah POS'});
      for (final product in [
        ['Coffee','Beverages',3000], ['Tea','Beverages',2000], ['Idli','Breakfast',4000],
        ['Dosa','Breakfast',6500], ['Meals','Lunch',12000], ['Water Bottle','Retail',2000],
        ['Snack Pack','Retail',3500], ['Juice','Beverages',5000],
      ]) {
        await d.insert('products', {'name':product[0], 'category':product[1], 'price_cents':product[2], 'stock':0, 'track_stock':0});
      }
    },
  );

  Future<List<Map<String,dynamic>>> products() async => (await db).query('products', where:'active=1', orderBy:'category, name');
  Future<List<Map<String,dynamic>>> sales() async => (await db).query('sales', orderBy:'id DESC', limit:500);
  Future<List<Map<String,dynamic>>> saleItems(int id) async => (await db).query('sale_items', where:'sale_id=?', whereArgs:[id]);
  Future<Map<String,String>> settings() async => {for (final row in await (await db).query('settings')) row['key'] as String: row['value'] as String};
  Future<void> setting(String key,String value) async => (await db).insert('settings', {'key':key,'value':value}, conflictAlgorithm:ConflictAlgorithm.replace);
  Future<void> saveProduct({int? id, required String name, required String category, required int priceCents, required int stock, required bool trackStock}) async {
    final data = {'name':name,'category':category,'price_cents':priceCents,'stock':stock,'track_stock':trackStock?1:0,'active':1};
    if (id == null) {await (await db).insert('products',data);} else {await (await db).update('products',data,where:'id=?',whereArgs:[id]);}
  }
  Future<void> archiveProduct(int id) async => (await db).update('products',{'active':0},where:'id=?',whereArgs:[id]);

  Future<int> checkout({required String mode, String? table, required Map<int,int> quantities, required List<Map<String,dynamic>> catalog, required int discountCents, required double taxRate, required String payment}) async {
    final database=await db;
    return database.transaction((txn) async {
      final items=<Map<String,dynamic>>[];
      var subtotal=0;
      for (final entry in quantities.entries) {
        if (entry.value <= 0) continue;
        final matches=catalog.where((x)=>x['id']==entry.key);
        if (matches.isEmpty) throw StateError('Product no longer exists');
        final item=matches.first;
        final latest=(await txn.query('products',where:'id=? AND active=1',whereArgs:[entry.key])).firstOrNull;
        if (latest==null) throw StateError('Product unavailable: ${item['name']}');
        if (latest['track_stock']==1 && (latest['stock'] as int)<entry.value) throw StateError('Insufficient stock: ${item['name']}');
        subtotal+=(latest['price_cents'] as int)*entry.value;
        items.add({...latest,'quantity':entry.value});
      }
      if (items.isEmpty) throw StateError('Cart is empty');
      if (discountCents<0 || discountCents>subtotal) throw StateError('Invalid discount');
      final tax=((subtotal-discountCents)*taxRate/100).round();
      final total=subtotal-discountCents+tax;
      final saleId=await txn.insert('sales',{'created_at':DateTime.now().toIso8601String(),'mode':mode,'table_no':table,'subtotal_cents':subtotal,'discount_cents':discountCents,'tax_cents':tax,'total_cents':total,'payment':payment});
      for(final item in items) {
        await txn.insert('sale_items',{'sale_id':saleId,'product_id':item['id'],'product_name':item['name'],'quantity':item['quantity'],'unit_cents':item['price_cents']});
        if(item['track_stock']==1) await txn.rawUpdate('UPDATE products SET stock=stock-? WHERE id=?',[item['quantity'],item['id']]);
      }
      return saleId;
    });
  }

  Future<String> exportJson() async {
    final database=await db;
    final data=<String,dynamic>{'format':'bettaiah-pos-backup','version':1,'created_at':DateTime.now().toIso8601String()};
    for (final table in ['products','sales','sale_items','settings']) {data[table]=await database.query(table);}
    return const JsonEncoder.withIndent('  ').convert(data);
  }
  Future<void> importJson(String raw) async {
    final decoded=jsonDecode(raw);
    if(decoded is! Map || decoded['format']!='bettaiah-pos-backup' || decoded['version']!=1) throw const FormatException('Not a Bettaiah POS backup');
    for(final table in ['products','sales','sale_items','settings']) {
      if(decoded[table] is! List) throw FormatException('Missing $table');
      for(final row in decoded[table]) {if(row is! Map) throw const FormatException('Invalid backup row');}
    }
    final database=await db;
    await database.transaction((txn) async {
      for(final table in ['sale_items','sales','products','settings']) {await txn.delete(table);}
      for(final table in ['products','sales','sale_items','settings']) {
        for(final row in decoded[table] as List) {await txn.insert(table,Map<String,Object?>.from(row as Map));}
      }
    });
  }
  Future<File> writeBackup(String folder) async {
    final file=File(p.join(folder,'bettaiah_pos_backup_${DateTime.now().millisecondsSinceEpoch}.json'));
    return file.writeAsString(await exportJson(),flush:true);
  }
}
