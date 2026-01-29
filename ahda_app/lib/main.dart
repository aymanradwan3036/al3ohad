import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  
  // Initialize Firebase Messaging
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  
  runApp(const AhdaApp());
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print('معالجة إشعار في الخلفية: ${message.messageId}');
}

class AhdaApp extends StatelessWidget {
  const AhdaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'نظام العُهَد والمصروفات',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        primarySwatch: Colors.blue,
        fontFamily: 'Cairo',
      ),
      home: const AuthGate(),
    );
  }
}

class Db {
  static final auth = FirebaseAuth.instance;
  static final fs = FirebaseFirestore.instance;
  static final storage = FirebaseStorage.instance;
  static final fn = FirebaseFunctions.instance;
  static final messaging = FirebaseMessaging.instance;
}

enum Role { employee, pm, gm }

Role parseRole(String v) {
  switch (v) {
    case 'PM':
      return Role.pm;
    case 'GM':
      return Role.gm;
    default:
      return Role.employee;
  }
}

class UserProfile {
  final String uid;
  final String email;
  final String name;
  final Role role;
  final bool isActive;

  UserProfile({
    required this.uid,
    required this.email,
    required this.name,
    required this.role,
    required this.isActive,
  });

  factory UserProfile.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return UserProfile(
      uid: doc.id,
      email: (d['email'] ?? '') as String,
      name: (d['name'] ?? '') as String,
      role: parseRole((d['role'] ?? 'EMPLOYEE') as String),
      isActive: (d['isActive'] ?? true) as bool,
    );
  }
}

String money(num v) => v.toStringAsFixed(2);

Future<void> showMsg(BuildContext context, String text) async {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

Future<bool> confirm(BuildContext context, String title, String body) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(_, false), child: const Text('إلغاء')),
        ElevatedButton(onPressed: () => Navigator.pop(_, true), child: const Text('تأكيد')),
      ],
    ),
  );
  return res ?? false;
}

Future<String?> pickAndUploadImage({
  required String storagePathPrefix,
  required String fileNameBase,
}) async {
  final picker = ImagePicker();
  final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 75);
  if (x == null) return null;

  final ext = x.name.split('.').last;
  final ref = Db.storage.ref().child('$storagePathPrefix/$fileNameBase.$ext');

  final bytes = await x.readAsBytes();
  await ref.putData(bytes, SettableMetadata(contentType: 'image/$ext'));
  return await ref.getDownloadURL();
}

// ---------- Ledger totals (APPROVED ONLY) ----------
Future<Map<String, double>> computeEmployeeTotals(String employeeId) async {
  // Only count APPROVED records
  final cashQ = await Db.fs
      .collection('cash_requests')
      .where('employeeId', isEqualTo: employeeId)
      .where('status', isEqualTo: 'APPROVED')
      .get();
  
  final expenseQ = await Db.fs
      .collection('expenses')
      .where('employeeId', isEqualTo: employeeId)
      .where('status', isEqualTo: 'APPROVED')
      .get();
  
  double inSum = 0;
  double outSum = 0;
  
  for (final d in cashQ.docs) {
    final amt = (d.data()['amount'] ?? 0).toDouble();
    inSum += amt;
  }
  
  for (final d in expenseQ.docs) {
    final amt = (d.data()['amount'] ?? 0).toDouble();
    outSum += amt;
  }
  
  return {'in': inSum, 'out': outSum, 'balance': inSum - outSum};
}

// ---------- Biometric Authentication ----------
class BiometricAuth {
  static final LocalAuthentication _auth = LocalAuthentication();
  
  static Future<bool> isAvailable() async {
    try {
      return await _auth.canCheckBiometrics && await _auth.isDeviceSupported();
    } catch (e) {
      return false;
    }
  }
  
  static Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'يرجى المصادقة للدخول إلى التطبيق',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
    } catch (e) {
      return false;
    }
  }
}

// ---------- Notification Service ----------
class NotificationService {
  static Future<void> initialize() async {
    NotificationSettings settings = await Db.messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    
    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      print('تم منح إذن الإشعارات');
      
      // Get FCM token
      String? token = await Db.messaging.getToken();
      print('FCM Token: $token');
      
      // Save token to user document
      final user = Db.auth.currentUser;
      if (user != null && token != null) {
        await Db.fs.collection('users').doc(user.uid).update({
          'fcmToken': token,
          'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
        });
      }
      
      // Listen to foreground messages
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        print('رسالة في المقدمة: ${message.notification?.title}');
      });
    }
  }
  
  static Future<void> sendNotification({
    required String userId,
    required String title,
    required String body,
  }) async {
    try {
      final userDoc = await Db.fs.collection('users').doc(userId).get();
      final fcmToken = userDoc.data()?['fcmToken'] as String?;
      
      if (fcmToken != null) {
        // Call Cloud Function to send notification
        final callable = Db.fn.httpsCallable('sendNotification');
        await callable.call({
          'token': fcmToken,
          'title': title,
          'body': body,
        });
      }
    } catch (e) {
      print('خطأ في إرسال الإشعار: $e');
    }
  }
}

// -------------------- Auth Gate --------------------
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: Db.auth.authStateChanges(),
      builder: (context, snap) {
        final user = snap.data;
        if (snap.connectionState == ConnectionState.waiting) {
          return const Splash();
        }
        if (user == null) return const LoginScreen();

        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: Db.fs.collection('users').doc(user.uid).get(),
          builder: (context, profSnap) {
            if (profSnap.connectionState == ConnectionState.waiting) return const Splash();

            if (!profSnap.hasData || !profSnap.data!.exists) {
              return MissingProfileScreen(uid: user.uid, email: user.email ?? '');
            }

            final profile = UserProfile.fromDoc(profSnap.data!);
            if (!profile.isActive) return DisabledAccountScreen(profile: profile);

            switch (profile.role) {
              case Role.pm:
                return PMDashboard(profile: profile);
              case Role.gm:
                return GMDashboard(profile: profile);
              case Role.employee:
              default:
                return EmployeeDashboard(profile: profile);
            }
          },
        );
      },
    );
  }
}

class Splash extends StatelessWidget {
  const Splash({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final email = TextEditingController();
  final pass = TextEditingController();
  bool loading = false;
  String? err;
  bool biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    final available = await BiometricAuth.isAvailable();
    setState(() => biometricAvailable = available);
  }

  Future<void> doLogin() async {
    setState(() {
      loading = true;
      err = null;
    });
    try {
      await Db.auth.signInWithEmailAndPassword(
        email: email.text.trim(),
        password: pass.text,
      );
      
      // Initialize notifications after login
      await NotificationService.initialize();
    } on FirebaseAuthException catch (e) {
      setState(() => err = e.message ?? e.code);
    } catch (e) {
      setState(() => err = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> doBiometricLogin() async {
    final authenticated = await BiometricAuth.authenticate();
    if (authenticated) {
      // Here you would retrieve saved credentials from secure storage
      // For now, just show a message
      await showMsg(context, 'تم التحقق بنجاح! يرجى إدخال بيانات الدخول.');
    }
  }

  @override
  void dispose() {
    email.dispose();
    pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تسجيل الدخول'),
        centerTitle: true,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.account_balance_wallet, size: 80, color: Colors.blue),
              const SizedBox(height: 24),
              const Text(
                'نظام العُهَد والمصروفات',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: email,
                decoration: const InputDecoration(
                  labelText: 'البريد الإلكتروني',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pass,
                decoration: const InputDecoration(
                  labelText: 'كلمة المرور',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 24),
              if (err != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(err!, style: const TextStyle(color: Colors.red)),
                ),
                const SizedBox(height: 16),
              ],
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: loading ? null : doLogin,
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(
                    loading ? 'جاري الدخول...' : 'تسجيل الدخول',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
              if (biometricAvailable) ...[
                const SizedBox(height: 16),
                const Text('أو', style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: doBiometricLogin,
                  icon: const Icon(Icons.fingerprint, size: 32),
                  label: const Text('تسجيل الدخول بالبصمة'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              const Text(
                'الدخول للموظفين المسجلين فقط',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class DisabledAccountScreen extends StatelessWidget {
  final UserProfile profile;
  const DisabledAccountScreen({super.key, required this.profile});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الحساب معطل')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.block, size: 80, color: Colors.red),
            const SizedBox(height: 24),
            Text(
              'الحساب (${profile.email}) معطل حاليًا',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 12),
            const Text(
              'يرجى التواصل مع مدير المشاريع لتفعيل الحساب',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => Db.auth.signOut(),
              icon: const Icon(Icons.logout),
              label: const Text('تسجيل الخروج'),
            ),
          ]),
        ),
      ),
    );
  }
}

class MissingProfileScreen extends StatelessWidget {
  final String uid;
  final String email;
  const MissingProfileScreen({super.key, required this.uid, required this.email});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ملف المستخدم غير موجود')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.person_off, size: 80, color: Colors.orange),
            const SizedBox(height: 24),
            const Text(
              'تم تسجيل الدخول بنجاح ولكن لا يوجد ملف تعريف لهذا الحساب',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            Text('معرف المستخدم: $uid', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Text('البريد الإلكتروني: $email', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => Db.auth.signOut(),
              icon: const Icon(Icons.logout),
              label: const Text('تسجيل الخروج'),
            ),
          ]),
        ),
      ),
    );
  }
}

// -------------------- EMPLOYEE --------------------
class EmployeeDashboard extends StatefulWidget {
  final UserProfile profile;
  const EmployeeDashboard({super.key, required this.profile});

  @override
  State<EmployeeDashboard> createState() => _EmployeeDashboardState();
}

class _EmployeeDashboardState extends State<EmployeeDashboard> {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    NotificationService.initialize();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    return Scaffold(
      appBar: AppBar(
        title: Text('الموظف: ${p.name}'),
        actions: [
          IconButton(
            onPressed: () => Db.auth.signOut(),
            icon: const Icon(Icons.logout),
            tooltip: 'تسجيل الخروج',
          ),
        ],
      ),
      body: IndexedStack(
        index: tab,
        children: [
          EmployeeHome(profile: p),
          EmployeeCashRequest(profile: p),
          EmployeeExpenseCreate(profile: p),
          EmployeeHistory(profile: p),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: tab,
        onTap: (i) => setState(() => tab = i),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.blue,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'الرئيسية'),
          BottomNavigationBarItem(icon: Icon(Icons.attach_money), label: 'طلب عهدة'),
          BottomNavigationBarItem(icon: Icon(Icons.receipt_long), label: 'تسجيل مصروف'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'السجل'),
        ],
      ),
    );
  }
}

class EmployeeHome extends StatelessWidget {
  final UserProfile profile;
  const EmployeeHome({super.key, required this.profile});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, double>>(
      future: computeEmployeeTotals(profile.uid),
      builder: (context, snap) {
        final totals = snap.data ?? {'in': 0, 'out': 0, 'balance': 0};
        return Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(children: [
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(children: [
                  const Text(
                    'ملخص الحساب',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildSummaryItem(
                        'إجمالي العهد المعتمدة',
                        money(totals['in']!),
                        Colors.green,
                        Icons.arrow_downward,
                      ),
                      _buildSummaryItem(
                        'إجمالي المصروفات المعتمدة',
                        money(totals['out']!),
                        Colors.red,
                        Icons.arrow_upward,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'الرصيد المتبقي: ',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${money(totals['balance']!)} ر.س',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: totals['balance']! >= 0 ? Colors.green : Colors.red,
                        ),
                      ),
                    ],
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'آخر الطلبات',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: Db.fs
                  .collection('cash_requests')
                  .where('employeeId', isEqualTo: profile.uid)
                  .orderBy('createdAt', descending: true)
                  .limit(5)
                  .snapshots(),
              builder: (context, snap) {
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) return const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('لا توجد طلبات عهد')));
                return Column(
                  children: docs.map((d) {
                    final x = d.data();
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.account_balance_wallet, color: Colors.blue),
                        title: Text('عهدة: ${money((x['amount'] ?? 0).toDouble())} ر.س'),
                        subtitle: Text('الحالة: ${_translateStatus(x['status'] ?? '')}'),
                        trailing: _getStatusIcon(x['status'] ?? ''),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ]),
        );
      },
    );
  }

  Widget _buildSummaryItem(String label, String value, Color color, IconData icon) {
    return Column(
      children: [
        Icon(icon, size: 40, color: color),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Text(
          '$value ر.س',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
        ),
      ],
    );
  }

  String _translateStatus(String status) {
    switch (status) {
      case 'PENDING_PM':
        return 'بانتظار مدير المشاريع';
      case 'PENDING_GM':
        return 'بانتظار المدير العام';
      case 'WAITING_TRANSFER':
        return 'بانتظار التحويل';
      case 'APPROVED':
        return 'معتمد';
      case 'REJECTED':
        return 'مرفوض';
      default:
        return status;
    }
  }

  Icon _getStatusIcon(String status) {
    switch (status) {
      case 'APPROVED':
        return const Icon(Icons.check_circle, color: Colors.green);
      case 'REJECTED':
        return const Icon(Icons.cancel, color: Colors.red);
      default:
        return const Icon(Icons.pending, color: Colors.orange);
    }
  }
}

class EmployeeCashRequest extends StatefulWidget {
  final UserProfile profile;
  const EmployeeCashRequest({super.key, required this.profile});

  @override
  State<EmployeeCashRequest> createState() => _EmployeeCashRequestState();
}

class _EmployeeCashRequestState extends State<EmployeeCashRequest> {
  String? projectId;
  final amount = TextEditingController();
  final reason = TextEditingController();
  bool loading = false;

  @override
  void dispose() {
    amount.dispose();
    reason.dispose();
    super.dispose();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> myProjectsStream() {
    return Db.fs.collection('project_members').where('employeeId', isEqualTo: widget.profile.uid).snapshots();
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> fetchProjectsByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final chunks = <List<String>>[];
    for (var i = 0; i < ids.length; i += 10) {
      chunks.add(ids.sublist(i, i + 10 > ids.length ? ids.length : i + 10));
    }
    final docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final c in chunks) {
      final q = await Db.fs.collection('projects').where(FieldPath.documentId, whereIn: c).get();
      docs.addAll(q.docs);
    }
    return docs;
  }

  Future<void> submit() async {
    final amt = double.tryParse(amount.text.trim());
    if (projectId == null || amt == null || amt <= 0 || reason.text.trim().isEmpty) {
      await showMsg(context, 'يرجى التحقق من جميع البيانات (المشروع/المبلغ/السبب)');
      return;
    }

    setState(() => loading = true);
    try {
      await Db.fs.collection('cash_requests').add({
        'employeeId': widget.profile.uid,
        'employeeName': widget.profile.name,
        'projectId': projectId,
        'amount': amt,
        'reason': reason.text.trim(),
        'status': 'PENDING_PM',
        'createdAt': FieldValue.serverTimestamp(),
      });
      
      amount.clear();
      reason.clear();
      setState(() => projectId = null);
      
      await showMsg(context, 'تم إرسال طلب العهدة بنجاح');
    } catch (e) {
      await showMsg(context, 'خطأ: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: myProjectsStream(),
      builder: (context, memSnap) {
        final members = memSnap.data?.docs ?? [];
        final ids = members.map((d) => (d.data()['projectId'] ?? '') as String).where((x) => x.isNotEmpty).toList();

        return FutureBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
          future: fetchProjectsByIds(ids),
          builder: (context, projSnap) {
            final projs = projSnap.data ?? [];
            return Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(children: [
                const Text(
                  'طلب عهدة جديدة',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<String>(
                  value: projectId,
                  items: projs
                      .map((p) => DropdownMenuItem(
                            value: p.id,
                            child: Text((p.data()['name'] ?? '') as String),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => projectId = v),
                  decoration: const InputDecoration(
                    labelText: 'اختر المشروع',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.work),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'مبلغ العهدة (ر.س)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.attach_money),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: reason,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'سبب الطلب',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.description),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: loading ? null : submit,
                    icon: const Icon(Icons.send),
                    label: Text(loading ? 'جاري الإرسال...' : 'إرسال الطلب'),
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 12),
                const Text(
                  'آخر طلبات العهدة',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: Db.fs
                      .collection('cash_requests')
                      .where('employeeId', isEqualTo: widget.profile.uid)
                      .orderBy('createdAt', descending: true)
                      .limit(10)
                      .snapshots(),
                  builder: (context, snap) {
                    final docs = snap.data?.docs ?? [];
                    if (docs.isEmpty) return const Text('لا توجد طلبات سابقة');
                    return Column(
                      children: docs.map((d) {
                        final x = d.data();
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.account_balance_wallet),
                            title: Text('مبلغ: ${money((x['amount'] ?? 0).toDouble())} ر.س'),
                            subtitle: Text('الحالة: ${x['status']}\nالسبب: ${x['reason'] ?? ''}'),
                            isThreeLine: true,
                          ),
                        );
                      }).toList(),
                    );
                  },
                )
              ]),
            );
          },
        );
      },
    );
  }
}

class EmployeeExpenseCreate extends StatefulWidget {
  final UserProfile profile;
  const EmployeeExpenseCreate({super.key, required this.profile});

  @override
  State<EmployeeExpenseCreate> createState() => _EmployeeExpenseCreateState();
}

class _EmployeeExpenseCreateState extends State<EmployeeExpenseCreate> {
  String? projectId;
  final amount = TextEditingController();
  final reason = TextEditingController();
  bool loading = false;
  String? receiptUrl;

  @override
  void dispose() {
    amount.dispose();
    reason.dispose();
    super.dispose();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> myProjectsStream() {
    return Db.fs.collection('project_members').where('employeeId', isEqualTo: widget.profile.uid).snapshots();
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> fetchProjectsByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final chunks = <List<String>>[];
    for (var i = 0; i < ids.length; i += 10) {
      chunks.add(ids.sublist(i, i + 10 > ids.length ? ids.length : i + 10));
    }
    final docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final c in chunks) {
      final q = await Db.fs.collection('projects').where(FieldPath.documentId, whereIn: c).get();
      docs.addAll(q.docs);
    }
    return docs;
  }

  Future<void> pickReceipt() async {
    try {
      final url = await pickAndUploadImage(
        storagePathPrefix: 'receipts/${widget.profile.uid}',
        fileNameBase: 'expense_${DateTime.now().millisecondsSinceEpoch}',
      );
      if (url != null) {
        setState(() => receiptUrl = url);
        await showMsg(context, 'تم رفع الفاتورة بنجاح');
      }
    } catch (e) {
      await showMsg(context, 'خطأ في رفع الفاتورة: $e');
    }
  }

  Future<void> submit() async {
    final amt = double.tryParse(amount.text.trim());
    if (projectId == null || amt == null || amt <= 0 || reason.text.trim().isEmpty) {
      await showMsg(context, 'يرجى التحقق من جميع البيانات (المشروع/المبلغ/السبب)');
      return;
    }
    if (receiptUrl == null) {
      await showMsg(context, 'يرجى رفع صورة الفاتورة أولاً');
      return;
    }

    setState(() => loading = true);
    try {
      await Db.fs.collection('expenses').add({
        'employeeId': widget.profile.uid,
        'employeeName': widget.profile.name,
        'projectId': projectId,
        'amount': amt,
        'reason': reason.text.trim(),
        'receiptUrl': receiptUrl,
        'status': 'PENDING_PM',
        'createdAt': FieldValue.serverTimestamp(),
      });
      
      amount.clear();
      reason.clear();
      setState(() {
        projectId = null;
        receiptUrl = null;
      });
      
      await showMsg(context, 'تم إرسال المصروف للمراجعة بنجاح');
    } catch (e) {
      await showMsg(context, 'خطأ: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: myProjectsStream(),
      builder: (context, memSnap) {
        final members = memSnap.data?.docs ?? [];
        final ids = members.map((d) => (d.data()['projectId'] ?? '') as String).where((x) => x.isNotEmpty).toList();

        return FutureBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
          future: fetchProjectsByIds(ids),
          builder: (context, projSnap) {
            final projs = projSnap.data ?? [];
            return Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(children: [
                const Text(
                  'تسجيل مصروف جديد',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<String>(
                  value: projectId,
                  items: projs
                      .map((p) => DropdownMenuItem(
                            value: p.id,
                            child: Text((p.data()['name'] ?? '') as String),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => projectId = v),
                  decoration: const InputDecoration(
                    labelText: 'اختر المشروع',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.work),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'مبلغ الصرف (ر.س)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.attach_money),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: reason,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'سبب الصرف',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.description),
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: loading ? null : pickReceipt,
                  icon: Icon(receiptUrl == null ? Icons.upload_file : Icons.check_circle),
                  label: Text(receiptUrl == null ? 'رفع صورة الفاتورة' : 'تم رفع الفاتورة ✓'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: BorderSide(
                      color: receiptUrl == null ? Colors.grey : Colors.green,
                      width: 2,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: loading ? null : submit,
                    icon: const Icon(Icons.send),
                    label: Text(loading ? 'جاري الإرسال...' : 'إرسال المصروف'),
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 12),
                const Text(
                  'آخر المصروفات',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: Db.fs
                      .collection('expenses')
                      .where('employeeId', isEqualTo: widget.profile.uid)
                      .orderBy('createdAt', descending: true)
                      .limit(10)
                      .snapshots(),
                  builder: (context, snap) {
                    final docs = snap.data?.docs ?? [];
                    if (docs.isEmpty) return const Text('لا توجد مصروفات سابقة');
                    return Column(
                      children: docs.map((d) {
                        final x = d.data();
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.receipt_long),
                            title: Text('مبلغ: ${money((x['amount'] ?? 0).toDouble())} ر.س'),
                            subtitle: Text('الحالة: ${x['status']}\nالسبب: ${x['reason'] ?? ''}'),
                            isThreeLine: true,
                            trailing: IconButton(
                              icon: const Icon(Icons.open_in_new),
                              onPressed: () => showDialog(
                                context: context,
                                builder: (_) => AlertDialog(
                                  title: const Text('رابط الفاتورة'),
                                  content: SelectableText(x['receiptUrl'] ?? ''),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(_),
                                      child: const Text('إغلاق'),
                                    )
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                )
              ]),
            );
          },
        );
      },
    );
  }
}

class EmployeeHistory extends StatelessWidget {
  final UserProfile profile;
  const EmployeeHistory({super.key, required this.profile});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(children: [
        const Text(
          'سجل العمليات الكامل',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        const Text(
          'طلبات العهد',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue),
        ),
        const SizedBox(height: 12),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Db.fs
              .collection('cash_requests')
              .where('employeeId', isEqualTo: profile.uid)
              .orderBy('createdAt', descending: true)
              .limit(30)
              .snapshots(),
          builder: (context, snap) {
            final docs = snap.data?.docs ?? [];
            if (docs.isEmpty) return const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('لا توجد طلبات عهد')));
            return Column(
              children: docs.map((d) {
                final x = d.data();
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_wallet, color: Colors.green),
                    title: Text('عهدة: ${money((x['amount'] ?? 0).toDouble())} ر.س'),
                    subtitle: Text('الحالة: ${x['status']}\nالسبب: ${x['reason'] ?? ''}'),
                    isThreeLine: true,
                  ),
                );
              }).toList(),
            );
          },
        ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        const Text(
          'المصروفات',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.red),
        ),
        const SizedBox(height: 12),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Db.fs
              .collection('expenses')
              .where('employeeId', isEqualTo: profile.uid)
              .orderBy('createdAt', descending: true)
              .limit(30)
              .snapshots(),
          builder: (context, snap) {
            final docs = snap.data?.docs ?? [];
            if (docs.isEmpty) return const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('لا توجد مصروفات')));
            return Column(
              children: docs.map((d) {
                final x = d.data();
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.receipt_long, color: Colors.red),
                    title: Text('مصروف: ${money((x['amount'] ?? 0).toDouble())} ر.س'),
                    subtitle: Text('الحالة: ${x['status']}\nالسبب: ${x['reason'] ?? ''}'),
                    isThreeLine: true,
                  ),
                );
              }).toList(),
            );
          },
        ),
      ]),
    );
  }
}

// -------------------- PM (Project Manager) --------------------
class PMDashboard extends StatefulWidget {
  final UserProfile profile;
  const PMDashboard({super.key, required this.profile});

  @override
  State<PMDashboard> createState() => _PMDashboardState();
}

class _PMDashboardState extends State<PMDashboard> {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    NotificationService.initialize();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    return Scaffold(
      appBar: AppBar(
        title: Text('مدير المشاريع: ${p.name}'),
        actions: [
          IconButton(
            onPressed: () => Db.auth.signOut(),
            icon: const Icon(Icons.logout),
            tooltip: 'تسجيل الخروج',
          ),
        ],
      ),
      body: IndexedStack(
        index: tab,
        children: [
          PMHome(profile: p),
          PMProjects(profile: p),
          PMEmployees(profile: p),
          PMApprovals(profile: p),
          PMReports(profile: p),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: tab,
        onTap: (i) => setState(() => tab = i),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.blue,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'الرئيسية'),
          BottomNavigationBarItem(icon: Icon(Icons.work), label: 'المشاريع'),
          BottomNavigationBarItem(icon: Icon(Icons.people), label: 'الموظفين'),
          BottomNavigationBarItem(icon: Icon(Icons.approval), label: 'الاعتمادات'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'التقارير'),
        ],
      ),
    );
  }
}

class PMHome extends StatelessWidget {
  final UserProfile profile;
  const PMHome({super.key, required this.profile});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(children: [
        const Text(
          'لوحة التحكم',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: Db.fs.collection('cash_requests').where('status', isEqualTo: 'PENDING_PM').snapshots(),
                builder: (context, snap) {
                  final count = snap.data?.docs.length ?? 0;
                  return _buildStatCard('طلبات عهد بانتظار الموافقة', count.toString(), Colors.orange, Icons.pending_actions);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: Db.fs.collection('expenses').where('status', isEqualTo: 'PENDING_PM').snapshots(),
                builder: (context, snap) {
                  final count = snap.data?.docs.length ?? 0;
                  return _buildStatCard('مصروفات بانتظار الموافقة', count.toString(), Colors.red, Icons.receipt_long);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: Db.fs.collection('projects').where('isActive', isEqualTo: true).snapshots(),
                builder: (context, snap) {
                  final count = snap.data?.docs.length ?? 0;
                  return _buildStatCard('المشاريع النشطة', count.toString(), Colors.blue, Icons.work);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: Db.fs.collection('users').where('role', isEqualTo: 'EMPLOYEE').where('isActive', isEqualTo: true).snapshots(),
                builder: (context, snap) {
                  final count = snap.data?.docs.length ?? 0;
                  return _buildStatCard('الموظفين النشطين', count.toString(), Colors.green, Icons.people);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          'آخر الطلبات',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Db.fs
              .collection('cash_requests')
              .where('status', isEqualTo: 'PENDING_PM')
              .orderBy('createdAt', descending: true)
              .limit(5)
              .snapshots(),
          builder: (context, snap) {
            final docs = snap.data?.docs ?? [];
            if (docs.isEmpty) return const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('لا توجد طلبات جديدة')));
            return Column(
              children: docs.map((d) {
                final x = d.data();
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_wallet, color: Colors.orange),
                    title: Text('عهدة: ${money((x['amount'] ?? 0).toDouble())} ر.س'),
                    subtitle: Text('الموظف: ${x['employeeName'] ?? x['employeeId']}\nالسبب: ${x['reason'] ?? ''}'),
                    isThreeLine: true,
                  ),
                );
              }).toList(),
            );
          },
        ),
      ]),
    );
  }

  Widget _buildStatCard(String title, String value, Color color, IconData icon) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, size: 40, color: color),
            const SizedBox(height: 12),
            Text(
              value,
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

class PMProjects extends StatefulWidget {
  final UserProfile profile;
  const PMProjects({super.key, required this.profile});

  @override
  State<PMProjects> createState() => _PMProjectsState();
}

class _PMProjectsState extends State<PMProjects> {
  final name = TextEditingController();
  final description = TextEditingController();
  bool loading = false;

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    super.dispose();
  }

  Future<void> createProject() async {
    if (name.text.trim().isEmpty) {
      await showMsg(context, 'يرجى إدخال اسم المشروع');
      return;
    }

    setState(() => loading = true);
    try {
      await Db.fs.collection('projects').add({
        'name': name.text.trim(),
        'description': description.text.trim(),
        'isActive': true,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': widget.profile.uid,
      });
      name.clear();
      description.clear();
      await showMsg(context, 'تم إنشاء المشروع بنجاح');
    } catch (e) {
      await showMsg(context, 'خطأ: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> toggleProjectStatus(String projectId, bool currentStatus) async {
    try {
      await Db.fs.collection('projects').doc(projectId).update({
        'isActive': !currentStatus,
      });
      await showMsg(context, currentStatus ? 'تم تعطيل المشروع' : 'تم تفعيل المشروع');
    } catch (e) {
      await showMsg(context, 'خطأ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(children: [
        const Text(
          'إدارة المشاريع',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: name,
          decoration: const InputDecoration(
            labelText: 'اسم المشروع',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.work),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: description,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'وصف المشروع',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.description),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            onPressed: loading ? null : createProject,
            icon: const Icon(Icons.add),
            label: Text(loading ? 'جاري الإنشاء...' : 'إنشاء مشروع جديد'),
          ),
        ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        const Text(
          'قائمة المشاريع',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Db.fs.collection('projects').orderBy('createdAt', descending: true).snapshots(),
          builder: (context, snap) {
            final docs = snap.data?.docs ?? [];
            if (docs.isEmpty) return const Text('لا توجد مشاريع');
            return Column(
              children: docs.map((d) {
                final x = d.data();
                final isActive = (x['isActive'] ?? true) as bool;
                return Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.work,
                      color: isActive ? Colors.green : Colors.grey,
                    ),
                    title: Text((x['name'] ?? '') as String),
                    subtitle: Text((x['description'] ?? '') as String),
                    trailing: Switch(
                      value: isActive,
                      onChanged: (val) => toggleProjectStatus(d.id, isActive),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ]),
    );
  }
}

class PMEmployees extends StatefulWidget {
  final UserProfile profile;
  const PMEmployees({super.key, required this.profile});

  @override
  State<PMEmployees> createState() => _PMEmployeesState();
}

class _PMEmployeesState extends State<PMEmployees> {
  final email = TextEditingController();
  final password = TextEditingController();
  final name = TextEditingController();
  bool loading = false;
  String? selectedEmployeeId;
  String? selectedProjectId;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> createEmployee() async {
    if (email.text.trim().isEmpty || password.text.trim().isEmpty || name.text.trim().isEmpty) {
      await showMsg(context, 'يرجى ملء جميع الحقول');
      return;
    }

    setState(() => loading = true);
    try {
      final callable = Db.fn.httpsCallable('createEmployee');
      await callable.call({
        'email': email.text.trim(),
        'password': password.text.trim(),
        'name': name.text.trim(),
      });
      
      email.clear();
      password.clear();
      name.clear();
      await showMsg(context, 'تم إنشاء حساب الموظف بنجاح');
    } catch (e) {
      await showMsg(context, 'خطأ: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> toggleEmployeeStatus(String userId, bool currentStatus) async {
    try {
      await Db.fs.collection('users').doc(userId).update({
        'isActive': !currentStatus,
      });
      await showMsg(context, currentStatus ? 'تم تعطيل الموظف' : 'تم تفعيل الموظف');
    } catch (e) {
      await showMsg(context, 'خطأ: $e');
    }
  }

  Future<void> linkEmployeeToProject() async {
    if (selectedEmployeeId == null || selectedProjectId == null) {
      await showMsg(context, 'يرجى اختيار الموظف والمشروع');
      return;
    }

    try {
      await Db.fs.collection('project_members').add({
        'employeeId': selectedEmployeeId,
        'projectId': selectedProjectId,
        'createdAt': FieldValue.serverTimestamp(),
      });
      
      setState(() {
        selectedEmployeeId = null;
        selectedProjectId = null;
      });
      
      await showMsg(context, 'تم ربط الموظف بالمشروع بنجاح');
    } catch (e) {
      await showMsg(context, 'خطأ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(children: [
        const Text(
          'إدارة الموظفين',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: name,
          decoration: const InputDecoration(
            labelText: 'اسم الموظف',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: email,
          decoration: const InputDecoration(
            labelText: 'البريد الإلكتروني',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.email),
          ),
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: password,
          decoration: const InputDecoration(
            labelText: 'كلمة المرور',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock),
          ),
          obscureText: true,
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            onPressed: loading ? null : createEmployee,
            icon: const Icon(Icons.person_add),
            label: Text(loading ? 'جاري الإنشاء...' : 'إنشاء موظف جديد'),
          ),
        ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        const Text(
          'قائمة الموظفين',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Db.fs.collection('users').where('role', isEqualTo: 'EMPLOYEE').snapshots(),
          builder: (context, snap) {
            final docs = snap.data?.docs ?? [];
            if (docs.isEmpty) return const Text('لا يوجد موظفين');
            return Column(
              children: docs.map((d) {
                final x = d.data();
                final isActive = (x['isActive'] ?? true) as bool;
                return Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.person,
                      color: isActive ? Colors.green : Colors.grey,
                    ),
                    title: Text((x['name'] ?? '') as String),
                    subtitle: Text((x['email'] ?? '') as String),
                    trailing: Switch(
                      value: isActive,
                      onChanged: (val) => toggleEmployeeStatus(d.id, isActive),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        const Text(
          'ربط موظف بمشروع',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Db.fs.collection('users').where('role', isEqualTo: 'EMPLOYEE').where('isActive', isEqualTo: true).snapshots(),
          builder: (context, snap) {
            final emps = snap.data?.docs ?? [];
            return DropdownButtonFormField<String>(
              value: selectedEmployeeId,
              items: emps
                  .map((e) => DropdownMenuItem(
                        value: e.id,
                        child: Text((e.data()['name'] ?? '') as String),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => selectedEmployeeId = v),
              decoration: const InputDecoration(
                labelText: 'اختر موظف',
                border: OutlineInputBorder(),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Db.fs.collection('projects').where('isActive', isEqualTo: true).snapshots(),
          builder: (context, snap) {
            final projs = snap.data?.docs ?? [];
            return DropdownButtonFormField<String>(
              value: selectedProjectId,
              items: projs
                  .map((p) => DropdownMenuItem(
                        value: p.id,
                        child: Text((p.data()['name'] ?? '') as String),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => selectedProjectId = v),
              decoration: const InputDecoration(
                labelText: 'اختر مشروع',
                border: OutlineInputBorder(),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            onPressed: linkEmployeeToProject,
            icon: const Icon(Icons.link),
            label: const Text('ربط الموظف بالمشروع'),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'الروابط الحالية (آخر 30)',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Db.fs.collection('project_members').orderBy('createdAt', descending: true).limit(30).snapshots(),
          builder: (context, snap) {
            final docs = snap.data?.docs ?? [];
            if (docs.isEmpty) return const Text('لا توجد روابط');
            return Column(
              children: docs.map((d) {
                final x = d.data();
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.link, size: 20),
                    title: Text('موظف: ${x['employeeId']}'),
                    subtitle: Text('مشروع: ${x['projectId']}'),
                    dense: true,
                  ),
                );
              }).toList(),
            );
          },
        ),
      ]),
    );
  }
}

class PMApprovals extends StatefulWidget {
  final UserProfile profile;
  const PMApprovals({super.key, required this.profile});

  @override
  State<PMApprovals> createState() => _PMApprovalsState();
}

class _PMApprovalsState extends State<PMApprovals> with SingleTickerProviderStateMixin {
  late final TabController tabs;

  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  Future<void> cashPmDecision(String id, bool approve, Map<String, dynamic> data) async {
    try {
      final call = Db.fn.httpsCallable('cash_pmDecision');
      await call.call({'id': id, 'approve': approve});
      
      // Send notification to employee
      final employeeId = data['employeeId'] as String;
      await NotificationService.sendNotification(
        userId: employeeId,
        title: approve ? 'تمت الموافقة على طلب العهدة' : 'تم رفض طلب العهدة',
        body: 'طلب العهدة بمبلغ ${money((data['amount'] ?? 0).toDouble())} ر.س ${approve ? 'تمت الموافقة عليه' : 'تم رفضه'}',
      );
      
      await showMsg(context, approve ? 'تمت الموافقة وإرساله للمدير العام' : 'تم الرفض');
    } catch (e) {
      await showMsg(context, 'خطأ: $e');
    }
  }

  Future<void> expensePmDecision(String id, bool approve, Map<String, dynamic> data) async {
    try {
      final call = Db.fn.httpsCallable('expense_pmDecision');
      await call.call({'id': id, 'approve': approve});
      
      // Send notification to employee
      final employeeId = data['employeeId'] as String;
      await NotificationService.sendNotification(
        userId: employeeId,
        title: approve ? 'تمت الموافقة على المصروف' : 'تم رفض المصروف',
        body: 'المصروف بمبلغ ${money((data['amount'] ?? 0).toDouble())} ر.س ${approve ? 'تمت الموافقة عليه' : 'تم رفضه'}',
      );
      
      await showMsg(context, approve ? 'تمت الموافقة وإرساله للمدير العام' : 'تم الرفض');
    } catch (e) {
      await showMsg(context, 'خطأ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      TabBar(
        controller: tabs,
        labelColor: Colors.blue,
        unselectedLabelColor: Colors.grey,
        tabs: const [
          Tab(text: 'طلبات العهدة'),
          Tab(text: 'المصروفات'),
        ],
      ),
      Expanded(
        child: TabBarView(controller: tabs, children: [
          // Cash Requests
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: Db.fs
                .collection('cash_requests')
                .where('status', isEqualTo: 'PENDING_PM')
                .orderBy('createdAt', descending: true)
                .snapshots(),
            builder: (context, snap) {
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) return const Center(child: Text('لا توجد طلبات بانتظار الموافقة'));
              return ListView(
                padding: const EdgeInsets.all(12),
                children: docs.map((d) {
                  final x = d.data();
                  return Card(
                    elevation: 2,
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.account_balance_wallet, color: Colors.blue),
                              const SizedBox(width: 8),
                              Text(
                                'عهدة: ${money((x['amount'] ?? 0).toDouble())} ر.س',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text('الموظف: ${x['employeeName'] ?? x['employeeId']}'),
                          Text('المشروع: ${x['projectId']}'),
                          Text('السبب: ${x['reason'] ?? ''}'),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () async {
                                  final ok = await confirm(context, 'رفض', 'هل تريد رفض هذا الطلب؟');
                                  if (!ok) return;
                                  await cashPmDecision(d.id, false, x);
                                },
                                icon: const Icon(Icons.close, color: Colors.red),
                                label: const Text('رفض', style: TextStyle(color: Colors.red)),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: () async {
                                  final ok = await confirm(context, 'موافقة', 'هل تريد الموافقة على هذا الطلب؟');
                                  if (!ok) return;
                                  await cashPmDecision(d.id, true, x);
                                },
                                icon: const Icon(Icons.check),
                                label: const Text('موافقة'),
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
          // Expenses
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: Db.fs
                .collection('expenses')
                .where('status', isEqualTo: 'PENDING_PM')
                .orderBy('createdAt', descending: true)
                .snapshots(),
            builder: (context, snap) {
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) return const Center(child: Text('لا توجد مصروفات بانتظار الموافقة'));
              return ListView(
                padding: const EdgeInsets.all(12),
                children: docs.map((d) {
                  final x = d.data();
                  return Card(
                    elevation: 2,
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.receipt_long, color: Colors.red),
                              const SizedBox(width: 8),
                              Text(
                                'مصروف: ${money((x['amount'] ?? 0).toDouble())} ر.س',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text('الموظف: ${x['employeeName'] ?? x['employeeId']}'),
                          Text('المشروع: ${x['projectId']}'),
                          Text('السبب: ${x['reason'] ?? ''}'),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: () => showDialog(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('رابط الفاتورة'),
                                content: SelectableText(x['receiptUrl'] ?? ''),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(_),
                                    child: const Text('إغلاق'),
                                  )
                                ],
                              ),
                            ),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('عرض الفاتورة'),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () async {
                                  final ok = await confirm(context, 'رفض', 'هل تريد رفض هذا المصروف؟');
                                  if (!ok) return;
                                  await expensePmDecision(d.id, false, x);
                                },
                                icon: const Icon(Icons.close, color: Colors.red),
                                label: const Text('رفض', style: TextStyle(color: Colors.red)),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: () async {
                                  final ok = await confirm(context, 'موافقة', 'هل تريد الموافقة على هذا المصروف؟');
                                  if (!ok) return;
                                  await expensePmDecision(d.id, true, x);
                                },
                                icon: const Icon(Icons.check),
                                label: const Text('موافقة'),
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ]),
      ),
    ]);
  }
}

class PMReports extends StatefulWidget {
  final UserProfile profile;
  const PMReports({super.key, required this.profile});

  @override
  State<PMReports> createState() => _PMReportsState();
}

class _PMReportsState extends State<PMReports> {
  String? selectedProjectId;
  
  Future<Map<String, dynamic>> generateEmployeeCustodyReport() async {
    final usersSnap = await Db.fs.collection('users').where('role', isEqualTo: 'EMPLOYEE').where('isActive', isEqualTo: true).get();
    
    List<Map<String, dynamic>> employeeData = [];
    double totalCustody = 0;
    double totalExpenses = 0;
    double totalBalance = 0;
    
    for (final userDoc in usersSnap.docs) {
      final totals = await computeEmployeeTotals(userDoc.id);
      final userData = userDoc.data();
      
      employeeData.add({
        'name': userData['name'] ?? '',
        'custody': totals['in']!,
        'expenses': totals['out']!,
        'balance': totals['balance']!,
      });
      
      totalCustody += totals['in']!;
      totalExpenses += totals['out']!;
      totalBalance += totals['balance']!;
    }
    
    return {
      'employees': employeeData,
      'totalCustody': totalCustody,
      'totalExpenses': totalExpenses,
      'totalBalance': totalBalance,
    };
  }
  
  Future<Map<String, dynamic>> generateProjectExpensesReport(String projectId) async {
    final expensesSnap = await Db.fs
        .collection('expenses')
        .where('projectId', isEqualTo: projectId)
        .where('status', isEqualTo: 'APPROVED')
        .get();
    
    Map<String, double> employeeExpenses = {};
    double totalProjectExpenses = 0;
    
    for (final doc in expensesSnap.docs) {
      final data = doc.data();
      final employeeName = data['employeeName'] ?? data['employeeId'] ?? 'غير معروف';
      final amount = (data['amount'] ?? 0).toDouble();
      
      employeeExpenses[employeeName] = (employeeExpenses[employeeName] ?? 0) + amount;
      totalProjectExpenses += amount;
    }
    
    return {
      'employeeExpenses': employeeExpenses,
      'totalProjectExpenses': totalProjectExpenses,
    };
  }

  Future<void> exportToExcel() async {
    try {
      final report = await generateEmployeeCustodyReport();
      final employees = report['employees'] as List<Map<String, dynamic>>;
      
      var excel = excel_lib.Excel.createExcel();
      var sheet = excel['تقرير العهد'];
      
      // Headers
      sheet.appendRow([
        excel_lib.TextCellValue('اسم الموظف'),
        excel_lib.TextCellValue('إجمالي العهد المعتمدة'),
        excel_lib.TextCellValue('إجمالي المصروفات المعتمدة'),
        excel_lib.TextCellValue('الرصيد المتبقي'),
      ]);
      
      // Data
      for (final emp in employees) {
        sheet.appendRow([
          excel_lib.TextCellValue(emp['name']),
          excel_lib.DoubleCellValue(emp['custody']),
          excel_lib.DoubleCellValue(emp['expenses']),
          excel_lib.DoubleCellValue(emp['balance']),
        ]);
      }
      
      // Totals
      sheet.appendRow([
        excel_lib.TextCellValue('الإجمالي'),
        excel_lib.DoubleCellValue(report['totalCustody']),
        excel_lib.DoubleCellValue(report['totalExpenses']),
        excel_lib.DoubleCellValue(report['totalBalance']),
      ]);
      
      // Save file
      final dir = await getApplicationDocumentsDirectory();
      final filePath = '${dir.path}/تقرير_العهد_${DateTime.now().millisecondsSinceEpoch}.xlsx';
      final file = File(filePath);
      await file.writeAsBytes(excel.encode()!);
      
      await showMsg(context, 'تم حفظ التقرير في: $filePath');
    } catch (e) {
      await showMsg(context, 'خطأ في تصدير التقرير: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(children: [
        const Text(
          'التقارير المالية',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        
        // Summary Cards
        FutureBuilder<Map<String, dynamic>>(
          future: generateEmployeeCustodyReport(),
          builder: (context, snap) {
            if (!snap.hasData) return const CircularProgressIndicator();
            
            final report = snap.data!;
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Card(
                        color: Colors.green.shade50,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              const Icon(Icons.arrow_downward, color: Colors.green, size: 32),
                              const SizedBox(height: 8),
                              const Text('إجمالي العهد', style: TextStyle(fontSize: 12)),
                              const SizedBox(height: 4),
                              Text(
                                '${money(report['totalCustody'])} ر.س',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Card(
                        color: Colors.red.shade50,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              const Icon(Icons.arrow_upward, color: Colors.red, size: 32),
                              const SizedBox(height: 8),
                              const Text('إجمالي المصروفات', style: TextStyle(fontSize: 12)),
                              const SizedBox(height: 4),
                              Text(
                                '${money(report['totalExpenses'])} ر.س',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.account_balance, color: Colors.blue, size: 40),
                        const SizedBox(width: 16),
                        Column(
                          children: [
                            const Text('الفرق الكلي', style: TextStyle(fontSize: 14)),
                            const SizedBox(height: 4),
                            Text(
                              '${money(report['totalBalance'])} ر.س',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: report['totalBalance'] >= 0 ? Colors.green : Colors.red,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: exportToExcel,
                icon: const Icon(Icons.download),
                label: const Text('تصدير إلى Excel'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.green,
                ),
              ),
            ),
          ],
        ),
        
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        
        // Employee Custody Report
        const Text(
          'تقرير عهدة الموظفين',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        
        FutureBuilder<Map<String, dynamic>>(
          future: generateEmployeeCustodyReport(),
          builder: (context, snap) {
            if (!snap.hasData) return const CircularProgressIndicator();
            
            final employees = snap.data!['employees'] as List<Map<String, dynamic>>;
            
            return Card(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('اسم الموظف', style: TextStyle(fontWeight: FontWeight.bold))),
                    DataColumn(label: Text('إجمالي العهد', style: TextStyle(fontWeight: FontWeight.bold))),
                    DataColumn(label: Text('إجمالي المصروفات', style: TextStyle(fontWeight: FontWeight.bold))),
                    DataColumn(label: Text('الرصيد المتبقي', style: TextStyle(fontWeight: FontWeight.bold))),
                  ],
                  rows: employees.map((emp) {
                    return DataRow(cells: [
                      DataCell(Text(emp['name'])),
                      DataCell(Text('${money(emp['custody'])} ر.س')),
                      DataCell(Text('${money(emp['expenses'])} ر.س')),
                      DataCell(Text(
                        '${money(emp['balance'])} ر.س',
                        style: TextStyle(
                          color: emp['balance'] >= 0 ? Colors.green : Colors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      )),
                    ]);
                  }).toList(),
                ),
              ),
            );
          },
        ),
        
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        
        // Project Expenses Report
        const Text(
          'تقرير مصروفات المشاريع',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Db.fs.collection('projects').where('isActive', isEqualTo: true).snapshots(),
          builder: (context, snap) {
            final projs = snap.data?.docs ?? [];
            return DropdownButtonFormField<String>(
              value: selectedProjectId,
              items: projs
                  .map((p) => DropdownMenuItem(
                        value: p.id,
                        child: Text((p.data()['name'] ?? '') as String),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => selectedProjectId = v),
              decoration: const InputDecoration(
                labelText: 'اختر المشروع',
                border: OutlineInputBorder(),
              ),
            );
          },
        ),
        
        const SizedBox(height: 16),
        
        if (selectedProjectId != null)
          FutureBuilder<Map<String, dynamic>>(
            future: generateProjectExpensesReport(selectedProjectId!),
            builder: (context, snap) {
              if (!snap.hasData) return const CircularProgressIndicator();
              
              final employeeExpenses = snap.data!['employeeExpenses'] as Map<String, double>;
              final totalProjectExpenses = snap.data!['totalProjectExpenses'] as double;
              
              return Column(
                children: [
                  Card(
                    color: Colors.orange.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'الإجمالي الكلي للمشروع:',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${money(totalProjectExpenses)} ر.س',
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.orange),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'تفصيل المصروفات حسب الموظف:',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 12),
                          ...employeeExpenses.entries.map((entry) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(entry.key),
                                  Text(
                                    '${money(entry.value)} ر.س',
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
      ]),
    );
  }
}

// -------------------- GM (General Manager) --------------------
class GMDashboard extends StatefulWidget {
  final UserProfile profile;
  const GMDashboard({super.key, required this.profile});

  @override
  State<GMDashboard> createState() => _GMDashboardState();
}

class _GMDashboardState extends State<GMDashboard> {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    NotificationService.initialize();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    return Scaffold(
      appBar: AppBar(
        title: Text('المدير العام: ${p.name}'),
        actions: [
          IconButton(
            onPressed: () => Db.auth.signOut(),
            icon: const Icon(Icons.logout),
            tooltip: 'تسجيل الخروج',
          ),
        ],
      ),
      body: IndexedStack(
        index: tab,
        children: [
          GMHome(profile: p),
          GMApproveCash(profile: p),
          GMApproveExpenses(profile: p),
          GMTransfers(profile: p),
          GMReports(profile: p),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: tab,
        onTap: (i) => setState(() => tab = i),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.blue,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'الرئيسية'),
          BottomNavigationBarItem(icon: Icon(Icons.approval), label: 'اعتماد العهد'),
          BottomNavigationBarItem(icon: Icon(Icons.receipt), label: 'اعتماد المصروفات'),
          BottomNavigationBarItem(icon: Icon(Icons.transfer_within_a_station), label: 'التحويلات'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'التقارير'),
        ],
      ),
    );
  }
}

class GMHome extends StatelessWidget {
  final UserProfile profile;
  const GMHome({super.key, required this.profile});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(children: [
        const Text(
          'لوحة تحكم المدير العام',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        
        // Financial Summary
        FutureBuilder<Map<String, dynamic>>(
          future: _generateFinancialSummary(),
          builder: (context, snap) {
            if (!snap.hasData) return const CircularProgressIndicator();
            
            final summary = snap.data!;
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Card(
                        color: Colors.green.shade50,
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              const Icon(Icons.arrow_downward, color: Colors.green, size: 40),
                              const SizedBox(height: 12),
                              const Text('إجمالي العهد المعتمدة', style: TextStyle(fontSize: 12)),
                              const SizedBox(height: 8),
                              Text(
                                '${money(summary['totalCustody'])} ر.س',
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Card(
                        color: Colors.red.shade50,
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              const Icon(Icons.arrow_upward, color: Colors.red, size: 40),
                              const SizedBox(height: 12),
                              const Text('إجمالي المصروفات المعتمدة', style: TextStyle(fontSize: 12)),
                              const SizedBox(height: 8),
                              Text(
                                '${money(summary['totalExpenses'])} ر.س',
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.red),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Card(
                  color: Colors.blue.shade50,
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.account_balance, color: Colors.blue, size: 50),
                        const SizedBox(width: 20),
                        Column(
                          children: [
                            const Text('الفرق الكلي', style: TextStyle(fontSize: 16)),
                            const SizedBox(height: 8),
                            Text(
                              '${money(summary['totalBalance'])} ر.س',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: summary['totalBalance'] >= 0 ? Colors.green : Colors.red,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        
        const SizedBox(height: 24),
        
        // Pending Approvals
        Row(
          children: [
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: Db.fs.collection('cash_requests').where('status', isEqualTo: 'PENDING_GM').snapshots(),
                builder: (context, snap) {
                  final count = snap.data?.docs.length ?? 0;
                  return Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          const Icon(Icons.pending_actions, color: Colors.orange, size: 32),
                          const SizedBox(height: 8),
                          Text(
                            '$count',
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.orange),
                          ),
                          const SizedBox(height: 4),
                          const Text('طلبات عهد بانتظار الاعتماد', textAlign: TextAlign.center, style: TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: Db.fs.collection('expenses').where('status', isEqualTo: 'PENDING_GM').snapshots(),
                builder: (context, snap) {
                  final count = snap.data?.docs.length ?? 0;
                  return Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          const Icon(Icons.receipt_long, color: Colors.red, size: 32),
                          const SizedBox(height: 8),
                          Text(
                            '$count',
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.red),
                          ),
                          const SizedBox(height: 4),
                          const Text('مصروفات بانتظار الاعتماد', textAlign: TextAlign.center, style: TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        
        const SizedBox(height: 12),
        
        StreamBuilder<QuerySnapshot>(
          stream: Db.fs.collection('cash_requests').where('status', isEqualTo: 'WAITING_TRANSFER').snapshots(),
          builder: (context, snap) {
            final count = snap.data?.docs.length ?? 0;
            return Card(
              color: Colors.purple.shade50,
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.transfer_within_a_station, color: Colors.purple, size: 32),
                    const SizedBox(width: 16),
                    Column(
                      children: [
                        Text(
                          '$count',
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.purple),
                        ),
                        const Text('طلبات بانتظار التحويل', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ]),
    );
  }

  Future<Map<String, dynamic>> _generateFinancialSummary() async {
    final usersSnap = await Db.fs.collection('users').where('role', isEqualTo: 'EMPLOYEE').get();
    
    double totalCustody = 0;
    double totalExpenses = 0;
    
    for (final userDoc in usersSnap.docs) {
      final totals = await computeEmployeeTotals(userDoc.id);
      totalCustody += totals['in']!;
      totalExpenses += totals['out']!;
    }
    
    return {
      'totalCustody': totalCustody,
      'totalExpenses': totalExpenses,
      'totalBalance': totalCustody - totalExpenses,
    };
  }
}

class GMApproveCash extends StatelessWidget {
  final UserProfile profile;
  const GMApproveCash({super.key, required this.profile});

  Future<void> cashGmDecision(BuildContext context, String id, bool approve, Map<String, dynamic> data) async {
    try {
      final call = Db.fn.httpsCallable('cash_gmDecision');
      await call.call({'id': id, 'approve': approve});
      
      // Send notification to employee
      final employeeId = data['employeeId'] as String;
      await NotificationService.sendNotification(
        userId: employeeId,
        title: approve ? 'تمت الموافقة النهائية على طلب العهدة' : 'تم رفض طلب العهدة من المدير العام',
        body: 'طلب العهدة بمبلغ ${money((data['amount'] ?? 0).toDouble())} ر.س ${approve ? 'تمت الموافقة عليه نهائيًا' : 'تم رفضه'}',
      );
      
      await showMsg(context, approve ? 'تمت الموافقة (بانتظار التحويل)' : 'تم الرفض');
    } catch (e) {
      await showMsg(context, 'خطأ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Db.fs
          .collection('cash_requests')
          .where('status', isEqualTo: 'PENDING_GM')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle_outline, size: 80, color: Colors.green),
                SizedBox(height: 16),
                Text('لا توجد طلبات عهد بانتظار الاعتماد', style: TextStyle(fontSize: 16)),
              ],
            ),
          );
        }
        
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'طلبات العهد بانتظار الاعتماد',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ...docs.map((d) {
              final x = d.data();
              return Card(
                elevation: 3,
                margin: const EdgeInsets.only(bottom: 16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.account_balance_wallet, color: Colors.blue, size: 32),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'عهدة: ${money((x['amount'] ?? 0).toDouble())} ر.س',
                                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  'الموظف: ${x['employeeName'] ?? x['employeeId']}',
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.work, size: 16, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text('المشروع: ${x['projectId']}'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.description, size: 16, color: Colors.grey),
                          const SizedBox(width: 8),
                          Expanded(child: Text('السبب: ${x['reason'] ?? ''}')),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () async {
                              final ok = await confirm(context, 'رفض الطلب', 'هل أنت متأكد من رفض هذا الطلب؟');
                              if (!ok) return;
                              await cashGmDecision(context, d.id, false, x);
                            },
                            icon: const Icon(Icons.close, color: Colors.red),
                            label: const Text('رفض', style: TextStyle(color: Colors.red)),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.red),
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            ),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: () async {
                              final ok = await confirm(context, 'اعتماد الطلب', 'بعد الموافقة سيصبح الطلب بانتظار التحويل. هل تريد المتابعة؟');
                              if (!ok) return;
                              await cashGmDecision(context, d.id, true, x);
                            },
                            icon: const Icon(Icons.check_circle),
                            label: const Text('اعتماد'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ],
        );
      },
    );
  }
}

class GMApproveExpenses extends StatelessWidget {
  final UserProfile profile;
  const GMApproveExpenses({super.key, required this.profile});

  Future<void> expenseGmDecision(BuildContext context, String id, bool approve, Map<String, dynamic> data) async {
    try {
      final call = Db.fn.httpsCallable('expense_gmDecision');
      await call.call({'id': id, 'approve': approve});
      
      // Send notification to employee
      final employeeId = data['employeeId'] as String;
      await NotificationService.sendNotification(
        userId: employeeId,
        title: approve ? 'تم اعتماد المصروف' : 'تم رفض المصروف من المدير العام',
        body: 'المصروف بمبلغ ${money((data['amount'] ?? 0).toDouble())} ر.س ${approve ? 'تم اعتماده والخصم من الرصيد' : 'تم رفضه'}',
      );
      
      await showMsg(context, approve ? 'تم الاعتماد والخصم تلقائيًا من الرصيد' : 'تم الرفض');
    } catch (e) {
      await showMsg(context, 'خطأ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Db.fs
          .collection('expenses')
          .where('status', isEqualTo: 'PENDING_GM')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle_outline, size: 80, color: Colors.green),
                SizedBox(height: 16),
                Text('لا توجد مصروفات بانتظار الاعتماد', style: TextStyle(fontSize: 16)),
              ],
            ),
          );
        }
        
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'المصروفات بانتظار الاعتماد',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ...docs.map((d) {
              final x = d.data();
              return Card(
                elevation: 3,
                margin: const EdgeInsets.only(bottom: 16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.receipt_long, color: Colors.red, size: 32),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'مصروف: ${money((x['amount'] ?? 0).toDouble())} ر.س',
                                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  'الموظف: ${x['employeeName'] ?? x['employeeId']}',
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.work, size: 16, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text('المشروع: ${x['projectId']}'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.description, size: 16, color: Colors.grey),
                          const SizedBox(width: 8),
                          Expanded(child: Text('السبب: ${x['reason'] ?? ''}')),
                        ],
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => showDialog(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('رابط الفاتورة'),
                            content: SelectableText(x['receiptUrl'] ?? ''),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(_),
                                child: const Text('إغلاق'),
                              )
                            ],
                          ),
                        ),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('عرض الفاتورة'),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () async {
                              final ok = await confirm(context, 'رفض المصروف', 'هل أنت متأكد من رفض هذا المصروف؟');
                              if (!ok) return;
                              await expenseGmDecision(context, d.id, false, x);
                            },
                            icon: const Icon(Icons.close, color: Colors.red),
                            label: const Text('رفض', style: TextStyle(color: Colors.red)),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.red),
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            ),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: () async {
                              final ok = await confirm(context, 'اعتماد المصروف', 'سيتم الخصم تلقائيًا من رصيد الموظف. هل تريد المتابعة؟');
                              if (!ok) return;
                              await expenseGmDecision(context, d.id, true, x);
                            },
                            icon: const Icon(Icons.check_circle),
                            label: const Text('اعتماد'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ],
        );
      },
    );
  }
}

class GMTransfers extends StatelessWidget {
  final UserProfile profile;
  const GMTransfers({super.key, required this.profile});

  Future<void> completeTransfer(BuildContext context, String cashId, Map<String, dynamic> data) async {
    final employeeId = (data['employeeId'] ?? '') as String;

    final ok = await confirm(context, 'تأكيد التحويل', 'سيتم رفع إشعار التحويل ثم إضافة العهدة لرصيد الموظف. هل تريد المتابعة؟');
    if (!ok) return;

    final url = await pickAndUploadImage(
      storagePathPrefix: 'transfer_proofs/$employeeId',
      fileNameBase: 'transfer_${DateTime.now().millisecondsSinceEpoch}',
    );
    if (url == null) return;

    try {
      final call = Db.fn.httpsCallable('cash_completeTransfer');
      await call.call({'id': cashId, 'transferProofUrl': url});
      
      // Send notification to employee
      await NotificationService.sendNotification(
        userId: employeeId,
        title: 'تم تحويل العهدة',
        body: 'تم تحويل مبلغ ${money((data['amount'] ?? 0).toDouble())} ر.س إلى حسابك',
      );
      
      await showMsg(context, 'تم التحويل وإضافة العهدة للرصيد بنجاح');
    } catch (e) {
      await showMsg(context, 'خطأ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Db.fs
          .collection('cash_requests')
          .where('status', isEqualTo: 'WAITING_TRANSFER')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle_outline, size: 80, color: Colors.green),
                SizedBox(height: 16),
                Text('لا توجد طلبات بانتظار التحويل', style: TextStyle(fontSize: 16)),
              ],
            ),
          );
        }
        
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'طلبات بانتظار التحويل',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ...docs.map((d) {
              final x = d.data();
              return Card(
                elevation: 3,
                margin: const EdgeInsets.only(bottom: 16),
                color: Colors.purple.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.transfer_within_a_station, color: Colors.purple, size: 32),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'مبلغ التحويل: ${money((x['amount'] ?? 0).toDouble())} ر.س',
                                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  'الموظف: ${x['employeeName'] ?? x['employeeId']}',
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.work, size: 16, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text('المشروع: ${x['projectId']}'),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => completeTransfer(context, d.id, x),
                          icon: const Icon(Icons.upload_file),
                          label: const Text('رفع إشعار التحويل وإكمال العملية'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.purple,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ],
        );
      },
    );
  }
}

class GMReports extends StatefulWidget {
  final UserProfile profile;
  const GMReports({super.key, required this.profile});

  @override
  State<GMReports> createState() => _GMReportsState();
}

class _GMReportsState extends State<GMReports> {
  String? selectedProjectId;
  
  Future<Map<String, dynamic>> generateEmployeeCustodyReport() async {
    final usersSnap = await Db.fs.collection('users').where('role', isEqualTo: 'EMPLOYEE').where('isActive', isEqualTo: true).get();
    
    List<Map<String, dynamic>> employeeData = [];
    double totalCustody = 0;
    double totalExpenses = 0;
    double totalBalance = 0;
    
    for (final userDoc in usersSnap.docs) {
      final totals = await computeEmployeeTotals(userDoc.id);
      final userData = userDoc.data();
      
      employeeData.add({
        'name': userData['name'] ?? '',
        'custody': totals['in']!,
        'expenses': totals['out']!,
        'balance': totals['balance']!,
      });
      
      totalCustody += totals['in']!;
      totalExpenses += totals['out']!;
      totalBalance += totals['balance']!;
    }
    
    return {
      'employees': employeeData,
      'totalCustody': totalCustody,
      'totalExpenses': totalExpenses,
      'totalBalance': totalBalance,
    };
  }
  
  Future<Map<String, dynamic>> generateProjectExpensesReport(String projectId) async {
    final expensesSnap = await Db.fs
        .collection('expenses')
        .where('projectId', isEqualTo: projectId)
        .where('status', isEqualTo: 'APPROVED')
        .get();
    
    Map<String, double> employeeExpenses = {};
    double totalProjectExpenses = 0;
    
    for (final doc in expensesSnap.docs) {
      final data = doc.data();
      final employeeName = data['employeeName'] ?? data['employeeId'] ?? 'غير معروف';
      final amount = (data['amount'] ?? 0).toDouble();
      
      employeeExpenses[employeeName] = (employeeExpenses[employeeName] ?? 0) + amount;
      totalProjectExpenses += amount;
    }
    
    return {
      'employeeExpenses': employeeExpenses,
      'totalProjectExpenses': totalProjectExpenses,
    };
  }

  Future<void> exportToExcel() async {
    try {
      final report = await generateEmployeeCustodyReport();
      final employees = report['employees'] as List<Map<String, dynamic>>;
      
      var excel = excel_lib.Excel.createExcel();
      var sheet = excel['تقرير العهد والمصروفات'];
      
      // Headers
      sheet.appendRow([
        excel_lib.TextCellValue('اسم الموظف'),
        excel_lib.TextCellValue('إجمالي العهد المعتمدة (ر.س)'),
        excel_lib.TextCellValue('إجمالي المصروفات المعتمدة (ر.س)'),
        excel_lib.TextCellValue('الرصيد المتبقي (ر.س)'),
      ]);
      
      // Data
      for (final emp in employees) {
        sheet.appendRow([
          excel_lib.TextCellValue(emp['name']),
          excel_lib.DoubleCellValue(emp['custody']),
          excel_lib.DoubleCellValue(emp['expenses']),
          excel_lib.DoubleCellValue(emp['balance']),
        ]);
      }
      
      // Totals
      sheet.appendRow([
        excel_lib.TextCellValue('الإجمالي الكلي'),
        excel_lib.DoubleCellValue(report['totalCustody']),
        excel_lib.DoubleCellValue(report['totalExpenses']),
        excel_lib.DoubleCellValue(report['totalBalance']),
      ]);
      
      // Save file
      final dir = await getApplicationDocumentsDirectory();
      final filePath = '${dir.path}/تقرير_مالي_شامل_${DateTime.now().millisecondsSinceEpoch}.xlsx';
      final file = File(filePath);
      await file.writeAsBytes(excel.encode()!);
      
      await showMsg(context, 'تم حفظ التقرير بنجاح في: $filePath');
    } catch (e) {
      await showMsg(context, 'خطأ في تصدير التقرير: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(children: [
        const Text(
          'التقارير المالية الشاملة',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        
        // Summary Cards
        FutureBuilder<Map<String, dynamic>>(
          future: generateEmployeeCustodyReport(),
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            
            final report = snap.data!;
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Card(
                        color: Colors.green.shade50,
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              const Icon(Icons.arrow_downward, color: Colors.green, size: 40),
                              const SizedBox(height: 12),
                              const Text('إجمالي العهد', style: TextStyle(fontSize: 12)),
                              const SizedBox(height: 8),
                              Text(
                                '${money(report['totalCustody'])} ر.س',
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Card(
                        color: Colors.red.shade50,
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              const Icon(Icons.arrow_upward, color: Colors.red, size: 40),
                              const SizedBox(height: 12),
                              const Text('إجمالي المصروفات', style: TextStyle(fontSize: 12)),
                              const SizedBox(height: 8),
                              Text(
                                '${money(report['totalExpenses'])} ر.س',
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.red),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Card(
                  color: Colors.blue.shade50,
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.account_balance, color: Colors.blue, size: 50),
                        const SizedBox(width: 20),
                        Column(
                          children: [
                            const Text('الفرق الكلي', style: TextStyle(fontSize: 18)),
                            const SizedBox(height: 8),
                            Text(
                              '${money(report['totalBalance'])} ر.س',
                              style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                color: report['totalBalance'] >= 0 ? Colors.green : Colors.red,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        
        const SizedBox(height: 24),
        SizedBox(
          height: 56,
          child: ElevatedButton.icon(
            onPressed: exportToExcel,
            icon: const Icon(Icons.file_download, size: 28),
            label: const Text('تصدير التقرير إلى Excel', style: TextStyle(fontSize: 16)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        
        const SizedBox(height: 24),
        const Divider(thickness: 2),
        const SizedBox(height: 16),
        
        // Employee Custody Report
        const Text(
          'تقرير عهدة الموظفين (المعتمد فقط)',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        
        FutureBuilder<Map<String, dynamic>>(
          future: generateEmployeeCustodyReport(),
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            
            final employees = snap.data!['employees'] as List<Map<String, dynamic>>;
            
            return Card(
              elevation: 2,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowColor: MaterialStateProperty.all(Colors.blue.shade50),
                  columns: const [
                    DataColumn(label: Text('اسم الموظف', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                    DataColumn(label: Text('إجمالي العهد', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                    DataColumn(label: Text('إجمالي المصروفات', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                    DataColumn(label: Text('الرصيد المتبقي', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                  ],
                  rows: employees.map((emp) {
                    return DataRow(cells: [
                      DataCell(Text(emp['name'], style: const TextStyle(fontSize: 13))),
                      DataCell(Text('${money(emp['custody'])} ر.س', style: const TextStyle(fontSize: 13))),
                      DataCell(Text('${money(emp['expenses'])} ر.س', style: const TextStyle(fontSize: 13))),
                      DataCell(Text(
                        '${money(emp['balance'])} ر.س',
                        style: TextStyle(
                          color: emp['balance'] >= 0 ? Colors.green : Colors.red,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      )),
                    ]);
                  }).toList(),
                ),
              ),
            );
          },
        ),
        
        const SizedBox(height: 24),
        const Divider(thickness: 2),
        const SizedBox(height: 16),
        
        // Project Expenses Report
        const Text(
          'تقرير مصروفات المشاريع (المعتمد فقط)',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Db.fs.collection('projects').where('isActive', isEqualTo: true).snapshots(),
          builder: (context, snap) {
            final projs = snap.data?.docs ?? [];
            return DropdownButtonFormField<String>(
              value: selectedProjectId,
              items: projs
                  .map((p) => DropdownMenuItem(
                        value: p.id,
                        child: Text((p.data()['name'] ?? '') as String),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => selectedProjectId = v),
              decoration: const InputDecoration(
                labelText: 'اختر المشروع',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.work),
              ),
            );
          },
        ),
        
        const SizedBox(height: 16),
        
        if (selectedProjectId != null)
          FutureBuilder<Map<String, dynamic>>(
            future: generateProjectExpensesReport(selectedProjectId!),
            builder: (context, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              
              final employeeExpenses = snap.data!['employeeExpenses'] as Map<String, double>;
              final totalProjectExpenses = snap.data!['totalProjectExpenses'] as double;
              
              return Column(
                children: [
                  Card(
                    color: Colors.orange.shade50,
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.calculate, color: Colors.orange, size: 32),
                              SizedBox(width: 12),
                              Text(
                                'الإجمالي الكلي للمشروع:',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          Text(
                            '${money(totalProjectExpenses)} ر.س',
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.orange),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.person, color: Colors.blue),
                              SizedBox(width: 8),
                              Text(
                                'تفصيل المصروفات حسب الموظف:',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (employeeExpenses.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(child: Text('لا توجد مصروفات معتمدة لهذا المشروع')),
                            )
                          else
                            ...employeeExpenses.entries.map((entry) {
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.grey.shade300),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(Icons.person_outline, size: 20, color: Colors.grey),
                                        const SizedBox(width: 8),
                                        Text(entry.key, style: const TextStyle(fontSize: 14)),
                                      ],
                                    ),
                                    Text(
                                      '${money(entry.value)} ر.س',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
      ]),
    );
  }
}
