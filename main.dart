import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const CatFeederApp());
}

class CatFeederApp extends StatelessWidget {
  const CatFeederApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Cat Feeder',
      theme: ThemeData(
        primarySwatch: Colors.orange,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
      ),
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 1;

  final List<Widget> _screens = [
    const BleSetupScreen(),
    const WifiControlScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.bluetooth),
            label: 'Налаштування Wi-Fi',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.pets),
            label: 'Керування',
          ),
        ],
      ),
    );
  }
}

class BleSetupScreen extends StatefulWidget {
  const BleSetupScreen({super.key});

  @override
  State<BleSetupScreen> createState() => _BleSetupScreenState();
}

class _BleSetupScreenState extends State<BleSetupScreen> {
  final TextEditingController ssidController = TextEditingController();
  final TextEditingController passController = TextEditingController();
  bool isSending = false;

  final String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String charUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  Future<void> sendWifiData() async {
    setState(() => isSending = true);
    try {
      await FlutterBluePlus.startScan(
          withNames: ["CatFeeder-Setup"], timeout: const Duration(seconds: 10));

      FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult r in results) {
          if (r.device.platformName == "CatFeeder-Setup") {
            await FlutterBluePlus.stopScan();
            await r.device.connect();

            List<BluetoothService> services = await r.device.discoverServices();
            for (BluetoothService service in services) {
              if (service.uuid.toString() == serviceUuid) {
                for (BluetoothCharacteristic char in service.characteristics) {
                  if (char.uuid.toString() == charUuid) {
                    String data = "${ssidController.text}\n${passController.text}";
                    await char.write(utf8.encode(data));
                    
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Дані відправлено! Годівниця перезавантажується.")),
                      );
                    }
                    await r.device.disconnect();
                    setState(() => isSending = false);
                    return;
                  }
                }
              }
            }
          }
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Помилка BLE: $e")));
      }
      setState(() => isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Підключення до Wi-Fi")),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: ssidController,
              decoration: const InputDecoration(labelText: "Назва мережі (SSID)", border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passController,
              decoration: const InputDecoration(labelText: "Пароль", border: OutlineInputBorder()),
              obscureText: true,
            ),
            const SizedBox(height: 30),
            ElevatedButton(
              onPressed: isSending ? null : sendWifiData,
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 55)),
              child: Text(isSending ? "Відправка..." : "Надіслати на годівницю"),
            )
          ],
        ),
      ),
    );
  }
}

class FeederSchedule {
  final int id;
  final String name;
  final String time;
  FeederSchedule({required this.id, required this.name, required this.time});
}

class WifiControlScreen extends StatefulWidget {
  const WifiControlScreen({super.key});

  @override
  State<WifiControlScreen> createState() => _WifiControlScreenState();
}

class _WifiControlScreenState extends State<WifiControlScreen> {

  final String baseUrl = "https://puzzling-entomb-bunkmate.ngrok-free.dev/feeder";
  
  List<FeederSchedule> activeSchedules = [];
  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    refreshSchedules();
  }

  Future<http.Response> _ngrokGet(String endpoint) async {
    final uri = Uri.parse('$baseUrl/$endpoint');
    return await http.get(
      uri,
      headers: {'ngrok-skip-browser-warning': 'true'},
    ).timeout(const Duration(seconds: 5));
  }

  Future<void> refreshSchedules() async {
    setState(() => isLoading = true);
    try {
      final response = await _ngrokGet('get_schedules.php');
      
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        List<FeederSchedule> tempList = [];
        String decodedBody = utf8.decode(response.bodyBytes);
        
        List<String> rawSchedules = decodedBody.split(';');
        for (String s in rawSchedules) {
          if (s.contains('|')) {
            List<String> parts = s.split('|');
            if (parts.length == 3) {
              tempList.add(FeederSchedule(
                id: int.tryParse(parts[0]) ?? 0,
                name: parts[1],
                time: parts[2],
              ));
            }
          }
        }
        
        setState(() {
          activeSchedules = tempList;
        });
      } else {
        setState(() { activeSchedules = []; });
      }
    } catch (e) {
      print("Не вдалося завантажити розклад: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Помилка з'єднання з сервером"))
        );
      }
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> submitSchedule(int? existingId, String name, String time) async {
    final parts = time.split(":");
    if (parts.length != 2) {
      _showError("Невірний формат часу. Використовуйте ГГ:ХХ");
      return;
    }
    int h = int.tryParse(parts[0]) ?? -1;
    int m = int.tryParse(parts[1]) ?? -1;
    if (h < 0 || h > 23 || m < 0 || m > 59) {
      _showError("Час має бути в межах 00:00 - 23:59");
      return;
    }

    Map<String, String> params = {
      'name': name,
      'hour': h.toString(),
      'minute': m.toString(),
    };
    if (existingId != null) {
      params['id'] = existingId.toString();
    }

    final uri = Uri.parse('$baseUrl/save_schedule.php').replace(queryParameters: params);
    
    try {
      final response = await http.get(
        uri,
        headers: {'ngrok-skip-browser-warning': 'true'},
      ).timeout(const Duration(seconds: 5));
      
      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Розклад збережено!"))
          );
        }
        await refreshSchedules();
      } else {
        _showError("Помилка збереження на сервері");
      }
    } catch (e) {
      _showError("Помилка зв'язку з сервером");
    }
  }

  Future<void> deleteSchedule(int id) async {
    final uri = Uri.parse('$baseUrl/save_schedule.php').replace(queryParameters: {'delete_id': id.toString()});
    try {
      final response = await http.get(
        uri,
        headers: {'ngrok-skip-browser-warning': 'true'},
      ).timeout(const Duration(seconds: 5));
      
      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Розклад видалено!"))
          );
        }
        refreshSchedules();
      } else {
        _showError("Помилка видалення");
      }
    } catch (e) {
      _showError("Помилка зв'язку з сервером");
    }
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void showScheduleDialog({FeederSchedule? scheduleToEdit}) {
    TextEditingController nameController = TextEditingController(text: scheduleToEdit?.name ?? "");
    TimeOfDay? selectedTime;
    
    if (scheduleToEdit != null) {
      final parts = scheduleToEdit.time.split(':');
      selectedTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    }

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Text(scheduleToEdit == null ? "Нове годування" : "Редагувати",
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: "Назва (напр. Сніданок)",
                      prefixIcon: Icon(Icons.label, color: Colors.orange),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 15),
                  ListTile(
                    leading: const Icon(Icons.access_time, color: Colors.orange),
                    title: Text(selectedTime == null 
                        ? "Оберіть час" 
                        : "${selectedTime!.hour.toString().padLeft(2, '0')}:${selectedTime!.minute.toString().padLeft(2, '0')}"),
                    trailing: const Icon(Icons.arrow_drop_down),
                    onTap: () async {
                      final TimeOfDay? picked = await showTimePicker(
                        context: context,
                        initialTime: selectedTime ?? TimeOfDay.now(),
                      );
                      if (picked != null) {
                        setStateDialog(() {
                          selectedTime = picked;
                        });
                      }
                    },
                    shape: RoundedRectangleBorder(
                      side: const BorderSide(color: Colors.grey),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("СКАСУВАТИ", style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    if (nameController.text.isEmpty) {
                      _showError("Введіть назву");
                      return;
                    }
                    if (selectedTime == null) {
                      _showError("Оберіть час");
                      return;
                    }
                    final timeStr = "${selectedTime!.hour.toString().padLeft(2, '0')}:${selectedTime!.minute.toString().padLeft(2, '0')}";
                    submitSchedule(scheduleToEdit?.id, nameController.text.trim(), timeStr);
                    Navigator.pop(context);
                  },
                  child: const Text("ЗБЕРЕГТИ", style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

Future<void> feedNow() async {
  try {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    
    final Map<String, String> requestHeaders = {
      "ngrok-skip-browser-warning": "69420"
    };
    
    final response = await http.get(
      Uri.parse('$baseUrl/feed.php?t=$timestamp'), 
      headers: requestHeaders 
    );

    if (response.statusCode == 200) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Команда успішно доставлена! 🐱"))
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Помилка сервера: ${response.statusCode}"))
        );
      }
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Сервер недоступний"))
      );
    }
  }
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Панель керування"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: refreshSchedules,
            tooltip: "Оновити список",
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text("Заплановані годування:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : activeSchedules.isEmpty
                      ? const Center(child: Text("Розкладів ще немає", style: TextStyle(fontSize: 16, color: Colors.grey)))
                      : ListView.builder(
                          itemCount: activeSchedules.length,
                          itemBuilder: (context, index) {
                            final schedule = activeSchedules[index];
                            return Card(
                              elevation: 3,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                              margin: const EdgeInsets.symmetric(vertical: 8),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
                                leading: const Icon(Icons.alarm, color: Colors.orange, size: 30),
                                title: Text(schedule.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                subtitle: Text(schedule.time,
                                    style: const TextStyle(fontSize: 18, color: Colors.green, fontWeight: FontWeight.bold)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit, color: Colors.blueAccent),
                                      onPressed: () => showScheduleDialog(scheduleToEdit: schedule),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.redAccent),
                                      onPressed: () => deleteSchedule(schedule.id),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
            const SizedBox(height: 15),
            ElevatedButton.icon(
              onPressed: () => showScheduleDialog(),
              icon: const Icon(Icons.add_alarm, color: Colors.white),
              label: const Text("ДОДАТИ РОЗКЛАД",
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                minimumSize: const Size(double.infinity, 60),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
            ),
            const SizedBox(height: 15),
            ElevatedButton(
              onPressed: feedNow,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                minimumSize: const Size(double.infinity, 70),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
              child: const Text("НАГОДУВАТИ ЗАРАЗ",
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}