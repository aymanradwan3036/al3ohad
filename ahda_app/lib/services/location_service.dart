// location_service.dart
// خدمة تتبع الموقع الجغرافي

import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

class LocationService {
  // التحقق من صلاحيات الموقع
  static Future<bool> checkPermissions() async {
    bool serviceEnabled;
    LocationPermission permission;

    // التحقق من تفعيل خدمات الموقع
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    // التحقق من الصلاحيات
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return false;
    }

    return true;
  }

  // الحصول على الموقع الحالي
  static Future<Map<String, dynamic>?> getCurrentLocation() async {
    try {
      // التحقق من الصلاحيات
      bool hasPermission = await checkPermissions();
      if (!hasPermission) {
        return null;
      }

      // الحصول على الموقع
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );

      // محاولة الحصول على العنوان
      String address = 'غير متوفر';
      try {
        List<Placemark> placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        
        if (placemarks.isNotEmpty) {
          Placemark place = placemarks[0];
          address = [
            place.street,
            place.subLocality,
            place.locality,
            place.administrativeArea,
            place.country,
          ].where((e) => e != null && e.isNotEmpty).join(', ');
        }
      } catch (e) {
        print('خطأ في الحصول على العنوان: $e');
      }

      return {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'address': address,
        'timestamp': DateTime.now().toIso8601String(),
      };
    } catch (e) {
      print('خطأ في الحصول على الموقع: $e');
      return null;
    }
  }

  // حساب المسافة بين نقطتين (بالكيلومتر)
  static double calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    return Geolocator.distanceBetween(lat1, lon1, lat2, lon2) / 1000;
  }

  // فتح إعدادات الموقع
  static Future<void> openLocationSettings() async {
    await Geolocator.openLocationSettings();
  }

  // فتح إعدادات التطبيق
  static Future<void> openAppSettings() async {
    await Geolocator.openAppSettings();
  }

  // تنسيق الإحداثيات للعرض
  static String formatCoordinates(double latitude, double longitude) {
    return '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
  }

  // إنشاء رابط Google Maps
  static String getGoogleMapsUrl(double latitude, double longitude) {
    return 'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude';
  }
}

// Widget لعرض معلومات الموقع
class LocationInfoWidget extends StatelessWidget {
  final Map<String, dynamic>? locationData;
  final bool isLoading;

  const LocationInfoWidget({
    Key? key,
    required this.locationData,
    this.isLoading = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: const [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('جاري تحديد الموقع...'),
            ],
          ),
        ),
      );
    }

    if (locationData == null) {
      return Card(
        color: Colors.orange.shade50,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Row(
                children: [
                  Icon(Icons.location_off, color: Colors.orange),
                  SizedBox(width: 8),
                  Text(
                    'لم يتم تحديد الموقع',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Text(
                'يرجى السماح بالوصول للموقع لتسجيل المصروف',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    final lat = locationData!['latitude'] as double;
    final lon = locationData!['longitude'] as double;
    final address = locationData!['address'] as String;
    final accuracy = locationData!['accuracy'] as double;

    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.location_on, color: Colors.green),
                SizedBox(width: 8),
                Text(
                  'تم تحديد الموقع بنجاح',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.place, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    address,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.my_location, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Text(
                  LocationService.formatCoordinates(lat, lon),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.gps_fixed, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Text(
                  'دقة: ${accuracy.toStringAsFixed(0)} متر',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                // فتح الموقع في خرائط جوجل
                final url = LocationService.getGoogleMapsUrl(lat, lon);
                // يمكنك استخدام url_launcher لفتح الرابط
                print('فتح الخريطة: $url');
              },
              icon: const Icon(Icons.map, size: 16),
              label: const Text('عرض على الخريطة', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}

// Dialog لطلب صلاحيات الموقع
class LocationPermissionDialog {
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.location_on, color: Colors.blue),
            SizedBox(width: 12),
            Text('صلاحية الموقع'),
          ],
        ),
        content: const Text(
          'يحتاج التطبيق إلى صلاحية الوصول للموقع لتسجيل موقع المصروف.\n\n'
          'هذا يساعد في التحقق من صحة المصروفات ومكان حدوثها.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('لاحقاً'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.check),
            label: const Text('السماح'),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  static Future<void> showSettingsDialog(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.settings, color: Colors.orange),
            SizedBox(width: 12),
            Text('تفعيل الموقع'),
          ],
        ),
        content: const Text(
          'يرجى تفعيل خدمات الموقع من الإعدادات للمتابعة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(context);
              await LocationService.openLocationSettings();
            },
            icon: const Icon(Icons.settings),
            label: const Text('فتح الإعدادات'),
          ),
        ],
      ),
    );
  }
}
