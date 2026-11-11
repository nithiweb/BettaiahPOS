import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'database.dart';

void main() { WidgetsFlutterBinding.ensureInitialized(); runApp(const BettaiahApp()); }
String money(int cents) => '₹${(cents/100).toStringAsFixed(2)}';
int toCents(String text) => ((double.tryParse(text.trim())??0)*100).round();

class BettaiahApp extends StatelessWidget {
  const BettaiahApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(title:'Bettaiah POS',debugShowCheckedModeBanner:false,theme:ThemeData(useMaterial3:true,colorSchemeSeed:const Color(0xff176c58),scaffoldBackgroundColor:const Color(0xfff7f9f8)),home:const HomePage());
}
class HomePage extends StatefulWidget {const HomePage({super.key}); @override State<HomePage> createState()=>_HomePageState();}
class _HomePageState extends State<HomePage> {
  int page=0; String mode='Restaurant', table='T1', category='All', query='';
  List<Map<String,dynamic>> products=[], sales=[]; Map<String,String> config={};
  final Map<int,int> cart={}; bool busy=true;
  final discountController=TextEditingController(text:'0');
  @override void initState(){super.initState(); refresh();}
  @override void dispose(){discountController.dispose();super.dispose();}
  Future<void> refresh() async {try {final p=await PosDb.instance.products();final s=await PosDb.instance.sales();final c=await PosDb.instance.settings();if(mounted)setState(() {products=p;sales=s;config=c;busy=false;});} catch(e){if(mounted){setState(()=>busy=false);error(e);}}}
  void error(Object e) {if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}
  int get subtotal => cart.entries.fold(0,(sum,e)=>sum+(products.where((p)=>p['id']==e.key).firstOrNull?['price_cents'] as int? ??0)*e.value);
  int get discount => toCents(discountController.text).clamp(0,subtotal);
  double get taxRate => double.tryParse(config['tax_percent']??'0')??0;
  int get tax => ((subtotal-discount)*taxRate/100).round();
  int get total => subtotal-discount+tax;
  void add(Map<String,dynamic> product){final id=product['id'] as int;final qty=cart[id]??0;if(product['track_stock']==1 && qty>=product['stock']){error('Not enough stock');return;}setState(()=>cart[id]=qty+1);}
  void changeQty(int id,int delta){final item=products.where((p)=>p['id']==id).firstOrNull;if(item==null)return;final next=(cart[id]??0)+delta;if(next>0 && item['track_stock']==1 && next>item['stock']){error('Not enough stock');return;}setState(() {if(next<=0){cart.remove(id);}else{cart[id]=next;}});}
  Future<void> checkout() async {
    if(cart.isEmpty)return;
    final payment=await showDialog<String>(context:context,builder:(ctx)=>SimpleDialog(title:Text('Collect ${money(total)}'),children:[for(final method in ['Cash','UPI','Card','Other'])SimpleDialogOption(onPressed:()=>Navigator.pop(ctx,method),child:Padding(padding:const EdgeInsets.all(8),child:Text(method)))]));
    if(payment==null)return;
    try {final id=await PosDb.instance.checkout(mode:mode,table:mode=='Restaurant'?table:null,quantities:Map.of(cart),catalog:products,discountCents:discount,taxRate:taxRate,payment:payment);if(!mounted)return;setState(()=>cart.clear());discountController.text='0';await refresh();if(mounted)showDialog<void>(context:context,builder:(ctx)=>AlertDialog(title:const Text('Sale completed'),content:Text('Receipt #$id saved locally.\nAmount: ${money(sales.first['total_cents'] as int)}\nPayment: $payment'),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Done'))]));}catch(e){error(e);}
  }
  @override Widget build(BuildContext context){final wide=MediaQuery.sizeOf(context).width>=750;return Scaffold(appBar:AppBar(title:const Text('Bettaiah POS',style:TextStyle(fontWeight:FontWeight.bold)),actions:[Padding(padding:const EdgeInsets.only(right:12),child:Center(child:Text('OFFLINE',style:TextStyle(color:Colors.green.shade700,fontWeight:FontWeight.bold))))]),body:busy?const Center(child:CircularProgressIndicator()):Row(children:[if(wide)NavigationRail(selectedIndex:page,onDestinationSelected:(v)=>setState(()=>page=v),labelType:NavigationRailLabelType.all,destinations:const [NavigationRailDestination(icon:Icon(Icons.point_of_sale),label:Text('Billing')),NavigationRailDestination(icon:Icon(Icons.inventory_2_outlined),label:Text('Products')),NavigationRailDestination(icon:Icon(Icons.receipt_long),label:Text('Sales')),NavigationRailDestination(icon:Icon(Icons.settings),label:Text('Settings'))]),Expanded(child:IndexedStack(index:page,children:[billing(wide),productPage(),salesPage(),settingsPage()]))]),bottomNavigationBar:wide?null:NavigationBar(selectedIndex:page,onDestinationSelected:(v)=>setState(()=>page=v),destinations:const [NavigationDestination(icon:Icon(Icons.point_of_sale),label:'Billing'),NavigationDestination(icon:Icon(Icons.inventory_2_outlined),label:'Products'),NavigationDestination(icon:Icon(Icons.receipt_long),label:'Sales'),NavigationDestination(icon:Icon(Icons.settings),label:'Settings')]));}
  Widget billing(bool wide){final cats=['All',...{for(final p in products)p['category'] as String}];final filtered=products.where((p)=>(category=='All'||p['category']==category)&&p['name'].toString().toLowerCase().contains(query.toLowerCase())).toList();return Padding(padding:const EdgeInsets.all(12),child:Column(children:[Wrap(spacing:10,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,children:[SegmentedButton<String>(segments:const [ButtonSegment(value:'Restaurant',label:Text('Restaurant'),icon:Icon(Icons.restaurant)),ButtonSegment(value:'Retail',label:Text('Retail'),icon:Icon(Icons.store))],selected:{mode},onSelectionChanged:(s)=>setState((){mode=s.first;cart.clear();})),if(mode=='Restaurant')DropdownButton<String>(value:table,items:[for(var i=1;i<=20;i++)DropdownMenuItem(value:'T$i',child:Text('Table $i'))],onChanged:(v)=>setState(()=>table=v!))]),const SizedBox(height:10),Expanded(child:wide?Row(children:[Expanded(flex:3,child:catalogView(cats,filtered)),const SizedBox(width:12),SizedBox(width:330,child:cartView())]):Column(children:[Expanded(child:catalogView(cats,filtered)),SizedBox(height:235,child:cartView())]))]));}
  
Widget catalogView(
  List<String> cats,
  List<Map<String, dynamic>> filtered,
) {
  return Column(
    children: [
      TextField(
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search),
          hintText: 'Search products',
          border: OutlineInputBorder(),
        ),
        onChanged: (v) => setState(() => query = v),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 42,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final c in cats)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(c),
                  selected: category == c,
                  onSelected: (_) => setState(() => category = c),
                ),
              ),
          ],
        ),
      ),
      Expanded(
        child: LayoutBuilder(
          builder: (context, box) {
            final cols = (box.maxWidth / 150).floor().clamp(2, 6);

            return GridView.builder(
              itemCount: filtered.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                childAspectRatio: 1.35,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemBuilder: (ctx, i) {
                final p = filtered[i];

                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => add(p),
                    child: Padding(
                      padding: const EdgeInsets.all(9),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            p['name'].toString(),
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Text(
                            money(p['price_cents'] as int),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xff176c58),
                            ),
                          ),
                          if (p['track_stock'] == 1)
                            Text(
                              "Stock: ${p['stock']}",
                              style: const TextStyle(fontSize: 11),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    ],
  );
}

  Widget cartView(){final entries=cart.entries.toList();return Card(child:Padding(padding:const EdgeInsets.all(10),child:Column(children:[const Align(alignment:Alignment.centerLeft,child:Text('Current bill',style:TextStyle(fontSize:17,fontWeight:FontWeight.bold))),Expanded(child:entries.isEmpty?const Center(child:Text('Tap products to add')):ListView.builder(itemCount:entries.length,itemBuilder:(ctx,i){final e=entries[i];final p=products.where((x)=>x['id']==e.key).first;return Row(children:[Expanded(child:Text(p['name'],maxLines:1,overflow:TextOverflow.ellipsis)),IconButton(icon:const Icon(Icons.remove_circle_outline),onPressed:()=>changeQty(e.key,-1)),Text('${e.value}'),IconButton(icon:const Icon(Icons.add_circle_outline),onPressed:()=>changeQty(e.key,1)),Text(money((p['price_cents'] as int)*e.value))]);})),Row(children:[const Text('Discount ₹'),const SizedBox(width:8),SizedBox(width:90,height:42,child:TextField(controller:discountController,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(border:OutlineInputBorder(),isDense:true),onChanged:(_)=>setState((){}))),const Spacer(),Text('Tax ${taxRate.toStringAsFixed(1)}%: ${money(tax)}')]),const SizedBox(height:8),SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:entries.isEmpty?null:checkout,icon:const Icon(Icons.check_circle_outline),label:Text('Charge ${money(total)}')))])));
  }
  
Widget productPage() {
  return Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Products',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            FilledButton.icon(
              onPressed: () => editProduct(),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
          ],
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: products.length,
          itemBuilder: (ctx, i) {
            final p = products[i];

            return ListTile(
              title: Text(p['name'].toString()),
              subtitle: Text(
                "${p['category']} · "
                "${money(p['price_cents'] as int)}"
                "${p['track_stock'] == 1 ? ' · Stock ${p['stock']}' : ''}",
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'edit') {
                    editProduct(product: p);
                  } else if (v == 'archive') {
                    await PosDb.instance.archiveProduct(p['id'] as int);
                    await refresh();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem<String>(
                    value: 'edit',
                    child: Text('Edit'),
                  ),
                  PopupMenuItem<String>(
                    value: 'archive',
                    child: Text('Archive'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );
}

  Future<void> editProduct({Map<String,dynamic>? product}) async {final name=TextEditingController(text:product?['name']??'');final cat=TextEditingController(text:product?['category']??'General');final price=TextEditingController(text:product==null?'':((product['price_cents'] as int)/100).toStringAsFixed(2));final stock=TextEditingController(text:'${product?['stock']??0}');var track=product?['track_stock']==1;final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setLocal)=>AlertDialog(title:Text(product==null?'Add product':'Edit product'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:name,decoration:const InputDecoration(labelText:'Name')),TextField(controller:cat,decoration:const InputDecoration(labelText:'Category')),TextField(controller:price,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Price ₹')),TextField(controller:stock,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Stock quantity')),SwitchListTile(title:const Text('Track stock'),value:track,onChanged:(v)=>setLocal(()=>track=v))])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Save'))])));if(ok==true){if(name.text.trim().isEmpty||cat.text.trim().isEmpty||double.tryParse(price.text)==null||double.parse(price.text)<0||int.tryParse(stock.text)==null||int.parse(stock.text)<0){error('Enter valid product details');return;}await PosDb.instance.saveProduct(id:product?['id'],name:name.text.trim(),category:cat.text.trim(),priceCents:toCents(price.text),stock:int.parse(stock.text),trackStock:track);await refresh();}}
  Widget salesPage(){final sum=sales.fold<int>(0,(n,s)=>n+(s['total_cents'] as int));return Column(children:[Padding(padding:const EdgeInsets.all(16),child:Row(children:[Expanded(child:Text('${sales.length} recorded sales',style:const TextStyle(fontWeight:FontWeight.bold))),Text('Total ${money(sum)}',style:const TextStyle(fontWeight:FontWeight.bold))])),Expanded(child:ListView.builder(itemCount:sales.length,itemBuilder:(ctx,i){final s=sales[i];return ListTile(title:Text('Receipt #${s['id']} · ${money(s['total_cents'])}'),subtitle:Text('${s['mode']}${s['table_no']!=null?' · ${s['table_no']}':''} · ${s['payment']} · ${s['created_at'].toString().replaceFirst('T',' ').substring(0,16)}'),trailing:const Icon(Icons.chevron_right),onTap:()async {final items=await PosDb.instance.saleItems(s['id']);if(!mounted)return;showDialog<void>(context:context,builder:(ctx)=>AlertDialog(title:Text('Receipt #${s['id']}'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[for(final item in items)Text('${item['product_name']} × ${item['quantity']} — ${money((item['unit_cents'] as int)*(item['quantity'] as int))}'),const Divider(),Text('Subtotal: ${money(s['subtotal_cents'])}'),Text('Discount: ${money(s['discount_cents'])}'),Text('Tax: ${money(s['tax_cents'])}'),Text('Total: ${money(s['total_cents'])}',style:const TextStyle(fontWeight:FontWeight.bold)),Text('Payment: ${s['payment']}')])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Close'))]));});}))]);}
  Widget settingsPage(){final tax=TextEditingController(text:config['tax_percent']??'0');final shop=TextEditingController(text:config['shop_name']??'Bettaiah POS');
return ListView(
  padding: const EdgeInsets.all(16),
  children: [
    FilledButton.icon(
      icon: const Icon(Icons.upgrade),
      label: const Text('Open Bettaiah POS V2'),
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => const BettaiahV2Page(),
          ),
        );
      },
    ),
    const SizedBox(height: 16),
const Text('Business settings',style:TextStyle(fontSize:21,fontWeight:FontWeight.bold)),const SizedBox(height:12),TextField(controller:shop,decoration:const InputDecoration(labelText:'Business name',border:OutlineInputBorder())),const SizedBox(height:12),TextField(controller:tax,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Tax rate (%)',border:OutlineInputBorder())),const SizedBox(height:12),FilledButton(onPressed:()async {final rate=double.tryParse(tax.text);if(rate==null||rate<0||rate>100){error('Tax must be between 0 and 100');return;}await PosDb.instance.setting('tax_percent',rate.toString());await PosDb.instance.setting('shop_name',shop.text.trim());await refresh();if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Settings saved')));},child:const Text('Save settings')),const Divider(height:36),const Text('Offline data',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),const SizedBox(height:8),const Text('All transactions remain on this device. Export a backup regularly. Restoring a backup REPLACES all current local data.'),const SizedBox(height:12),OutlinedButton.icon(onPressed:backup,icon:const Icon(Icons.ios_share),label:const Text('Export and share backup')),OutlinedButton.icon(onPressed:restore,icon:const Icon(Icons.restore),label:const Text('Restore backup from JSON')),const SizedBox(height:12),const Text('No account, cloud connection, or internet access is needed for billing.',style:TextStyle(color:Colors.black54))]);}
  Future<void> backup() async {try {final dir=await getTemporaryDirectory();final file=await PosDb.instance.writeBackup(dir.path);await SharePlus.instance.share(ShareParams(files:[XFile(file.path)],text:'Bettaiah POS offline backup — keep this file safe'));}catch(e){error(e);}}
  Future<void> restore() async {try {final picked=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['json']);if(picked==null||picked.files.single.path==null)return;if(!mounted)return;final confirm=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:const Text('Replace all local data?'),content:const Text('Restore will erase current products and sales and replace them with the selected backup. This cannot be undone.'),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Restore'))]));if(confirm!=true)return;final raw=await File(picked.files.single.path!).readAsString();await PosDb.instance.importJson(raw);if(!mounted)return;setState(()=>cart.clear());await refresh();if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Backup restored successfully')));}catch(e){error(e);}}
}

import 'v2_module.dart';
