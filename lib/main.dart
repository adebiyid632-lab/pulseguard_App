import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PulseGuard Telemedicine Platform',
      home: MainPlatformShell(),
    );
  }
}

class MainPlatformShell extends StatefulWidget {
  const MainPlatformShell({super.key});

  @override
  State<MainPlatformShell> createState() => _MainPlatformShellState();
}

class _MainPlatformShellState extends State<MainPlatformShell> {
  double bloodOxygen = 98.0; 
  double heartRate = 72.0;
  String statusMessage = "STABLE: Vitals are within normal thresholds.";
  
  bool isCrisisMode = false;
  bool isLiveStreaming = false;
  Timer? _streamTimer;
  Timer? _fetchTimer;
  
  final List<Map<String, dynamic>> historyLogs = [];
  
  double remoteOxygen = 98.0;
  double remoteHeartRate = 72.0;
  String remoteStatus = "Stable";
  String remoteLastUpdated = "No data fetched yet";

  @override
  void initState() {
    super.initState();
    _fetchTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
      _fetchVitalsFromCloud();
    });
  }

  void toggleLiveStreaming() {
    setState(() {
      isLiveStreaming = !isLiveStreaming;
    });

    if (isLiveStreaming) {
      _streamTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
        _generateAutomatedWatchData();
      });
    } else {
      _streamTimer?.cancel();
    }
  }

// 🔍 BLE ENGINE: Scans for nearby hardware nodes safely
  List<ScanResult> scanResults = [];
  bool isScanning = false;

  void startBluetoothScan() async {
    if (await FlutterBluePlus.isSupported == false) {
      developer.log("Bluetooth is not supported on this device.");
      return;
    }
    setState(() {
      isScanning = true;
      scanResults.clear();
    });
    FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        scanResults = results.where((r) => r.device.platformName.isNotEmpty).toList();
      });
    }, onError: (e) => developer.log("Scan error: $e"));
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
    setState(() {
      isScanning = false;
    });
  }

  // ☁️ UPLOAD: Sends patient data up to the cloud pipeline 
  void _sendVitalsToCloud({required double oxygen, required double heartRate, required String status}) async {
    try {
      final url = Uri.parse('https://firestore.googleapis.com/v1/projects/pulseguard-634cd/databases/(default)/documents/patient_vitals');
      
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'fields': {
            'blood_oxygen': {'doubleValue': oxygen},
            'heart_rate': {'doubleValue': heartRate},
            'triage_status': {'stringValue': status},
            'patient_id': {'stringValue': 'UNILAG_BME_2026_01'},
            'timestamp': {'stringValue': DateTime.now().toIso8601String()},
          }
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        developer.log("🚀 Ingestion Pipeline Active: Stream uploaded successfully.");
      }
    } catch (e) {
      developer.log("Stream out log: $e");
    }
  }

// ☁️ DOWNLOAD: Pulls the latest entry from the cloud safely via URL queries
  void _fetchVitalsFromCloud() async {
    if (!isLiveStreaming) return;
    try {
      final url = Uri.parse('https://firestore.googleapis.com/v1/projects/pulseguard-634cd/databases/(default)/documents:runQuery');
      
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'structuredQuery': {
            'from': [{'collectionId': 'patient_vitals'}],
            'orderBy': [
              {
                'field': {'fieldPath': 'timestamp'},
                'direction': 'DESCENDING'
              }
            ],
            'limit': 1
          }
        }),
      );

      if (response.statusCode == 200) {
        final List<dynamic> queryResults = jsonDecode(response.body);
        
        // Both warnings clear here by using explicit list indexing
        if (queryResults.isNotEmpty && queryResults !=[null] && queryResults[0]['document'] != null) {
          var latestDocFields = queryResults[0]['document']['fields'];
          
          setState(() {
            remoteOxygen = double.tryParse(latestDocFields['blood_oxygen']['doubleValue']?.toString() ?? '') ?? 98.0;
            remoteHeartRate = double.tryParse(latestDocFields['heart_rate']['doubleValue']?.toString() ?? '') ?? 72.0;
            remoteStatus = latestDocFields['triage_status']['stringValue']?.toString() ?? "Stable";
            
            DateTime now = DateTime.now();
            remoteLastUpdated = "${now.hour.toString().padLeft(2,'0')}:${now.minute.toString().padLeft(2,'0')}:${now.second.toString().padLeft(2,'0')}";
          });
        }
      }
    } catch (e) {
      developer.log("Fetch error tracking: $e");
    }
  }
  void _generateAutomatedWatchData() {
    final random = Random();
    setState(() {
      if (isCrisisMode) {
        bloodOxygen = 89.0 + random.nextInt(3).toDouble(); 
        heartRate = 106.0 + random.nextInt(12).toDouble(); 
        statusMessage = "CRITICAL ALERT: Vaso-occlusive crisis risk detected. Alerting caregivers.";
      } else {
        bloodOxygen = 96.0 + random.nextInt(4).toDouble(); 
        heartRate = 68.0 + random.nextInt(12).toDouble();  
        statusMessage = "STABLE: Vitals are within normal thresholds.";
      }

      String timestamp = "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}";
      bool isCritical = bloodOxygen < 93.0 || heartRate > 105.0;

      final Map<String, dynamic> newLogEntry = {
        "time": timestamp,
        "oxygen": "${bloodOxygen.toStringAsFixed(0)}%",
        "heartRate": "${heartRate.toStringAsFixed(0)} BPM",
        "status": isCritical ? "Critical" : "Stable",
        "isWarning": isCritical
      };

      historyLogs.insert(0, newLogEntry);

      if (historyLogs.length > 4) {
        historyLogs.removeLast();
      }

      _sendVitalsToCloud(
        oxygen: bloodOxygen,
        heartRate: heartRate,
        status: isCritical ? "Critical" : "Stable",
      );
    });
  }

  void toggleCrisisTrigger() {
    setState(() {
      isCrisisMode = !isCrisisMode;
      if (isLiveStreaming) {
        _generateAutomatedWatchData();
      }
    });
  }

  @override
  void dispose() {
    _streamTimer?.cancel();
    _fetchTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isLeftCritical = bloodOxygen < 93.0 || heartRate > 105.0;
    bool isRemoteCritical = remoteStatus == "Critical" || remoteOxygen < 93.0;

   return Scaffold(
      backgroundColor: const Color(0xFF0D1117), 
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.3, -0.5), 
            radius: 1.3,
            colors: [
            Color(0xFF24304A), // A lighter, vibrant clinical blue-grey for the center glow
            Color(0xFF090D16), // A much darker, near-black midnight navy for the edges
          ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
          builder: (context, constraints) {
            bool isWide = constraints.maxWidth > 800;
            return Flex(
              direction: isWide ? Axis.horizontal : Axis.vertical,
              children: [
                Expanded(
                  flex: 5,
                  child: Container(
                    color: const Color(0xFFF4F7FA),
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildSectionHeader("PATIENT MONITOR PLATFORM (NODE-01)", Colors.black87),
                        const SizedBox(height: 12),
                        
                        _buildStreamingBanner(),
                        const SizedBox(height: 12),

                        _buildTriageCard(isLeftCritical, statusMessage),
                        const SizedBox(height: 16),

                        Row(
                          children: [
                            Expanded(child: _buildDashboardCard("Local SpO₂ Sensor", "${bloodOxygen.toStringAsFixed(0)}%", Icons.opacity, Colors.blue)),
                            const SizedBox(width: 12),
                            Expanded(child: _buildDashboardCard("Local Pulse Core", "${heartRate.toStringAsFixed(0)} BPM", Icons.favorite, Colors.red)),
                          ],
                        ),
                        const SizedBox(height: 16),

                        const Text("LOCAL STREAM REPOSITORY ENGINE LOGS", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                        const SizedBox(height: 8),
                        
                        Expanded(child: _buildLocalLogView()),
                        const SizedBox(height: 12),

                        _buildCrisisButton(),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  flex: 5,
                  child: Container(
                    color: const Color(0xFF1C2541),
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildSectionHeader("CLINICAL TELEMETRY CARE STATION DASHBOARD", Colors.white),
                        const SizedBox(height: 12),

                        _buildCloudSyncStatusBadge(),
                        const SizedBox(height: 16),

                        _buildRemotePatientIdentifierCard(),
                        const SizedBox(height: 16),

                        // 🔘 Bluetooth Scanning Controller Button
                        ElevatedButton.icon(
                          onPressed: isScanning ? null : startBluetoothScan,
                          icon: isScanning 
                              ? const SizedBox(
                                  width: 16, 
                                  height: 16, 
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                )
                              : const Icon(Icons.bluetooth_searching, color: Colors.white),
                          label: Text(
                            isScanning ? "SCANNING FOR HARDWARE..." : "SEARCH FOR WEARABLE NODE",
                            style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1D2D44), // Deep slate blue that fits your theme
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            elevation: 2,
                          ),
                        ),

                        // 📋 Live Device Discovery List View
                        if (scanResults.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Container(
                            height: 110,
                            decoration: BoxDecoration(
                              color: const Color(0xFF0D1B2A),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: ListView.builder(
                              itemCount: scanResults.length,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemBuilder: (context, index) {
                                final device = scanResults[index].device;
                                return ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.watch, color: Colors.blueAccent, size: 18),
                                  title: Text(
                                    device.platformName, 
                                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                                  ),
                                  subtitle: Text(
                                    device.remoteId.toString(), 
                                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                                  ),
                                  trailing: const Icon(Icons.link_off, color: Colors.white24, size: 16),
                                );
                              },
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),

                        _buildRemoteAlarmBanner(isRemoteCritical),
                        const SizedBox(height: 20),

                        Row(
                          children: [
                            Expanded(child: _buildRemoteMetricCard("Cloud SpO₂ Readout", "${remoteOxygen.toStringAsFixed(0)}%", isRemoteCritical ? Colors.amber : Colors.cyan)),
                            const SizedBox(width: 12),
                            Expanded(child: _buildRemoteMetricCard("Cloud HR Readout", "${remoteHeartRate.toStringAsFixed(0)} BPM", isRemoteCritical ? Colors.redAccent : Colors.lightGreenAccent)),
                          ],
                        ),
                        
                        const Spacer(),
                        const Text("⚠️ SYSTEM DATA SECURED OVER SEAMLESS HTTPS NETWORK TRANSFERS", style: TextStyle(color: Colors.white30, fontSize: 10, letterSpacing: 0.5), textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
   );
  }

  Widget _buildSectionHeader(String label, Color color) {
    return Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color, letterSpacing: 1.0));
  }

  Widget _buildStreamingBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isLiveStreaming ? Colors.blue.withValues(alpha: 0.12) : Colors.grey.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(Icons.sensors, color: isLiveStreaming ? Colors.blue : Colors.grey, size: 18),
              const SizedBox(width: 8),
              Text(isLiveStreaming ? "TRANSMITTING DATA PACKETS" : "HARDWARE PATIENT DISCONNECTED", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: isLiveStreaming ? Colors.blue.shade900 : Colors.grey.shade800)),
            ],
          ),
          Switch(value: isLiveStreaming, onChanged: (val) => toggleLiveStreaming(), activeThumbColor: Colors.blue)
        ],
      ),
    );
  }

  Widget _buildTriageCard(bool critical, String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: critical ? const Color(0xFFD32F2F) : const Color(0xFF388E3C), borderRadius: BorderRadius.circular(8)),
      child: Text(message, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildDashboardCard(String subtitle, String val, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6)]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 10),
          Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          Text(val, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildLocalLogView() {
    if (historyLogs.isEmpty) {
      return const Center(child: Text("Activate the cloud tracking pipeline switch above to cycle data metrics.", style: TextStyle(color: Colors.grey, fontSize: 11)));
    }
    return ListView.builder(
      itemCount: historyLogs.length,
      itemBuilder: (context, index) {
        var log = historyLogs[index];
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(log['time']?.toString() ?? '', style: const TextStyle(color: Colors.grey, fontSize: 12)),
              Text("SpO₂: ${log['oxygen']?.toString() ?? ''}", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
              Text("HR: ${log['heartRate']?.toString() ?? ''}", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
              Text(log['status']?.toString() ?? '', style: TextStyle(color: log['isWarning'] == true ? Colors.red : Colors.green, fontWeight: FontWeight.bold, fontSize: 12)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCrisisButton() {
    return ElevatedButton(
      onPressed: toggleCrisisTrigger,
      style: ElevatedButton.styleFrom(backgroundColor: isCrisisMode ? const Color(0xFF388E3C) : const Color(0xFFD32F2F), padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
      child: Text(isCrisisMode ? "SIMULATE RESTING / HEALTHY VITALS" : "TRIGGER VOC CRISIS EVENT DATA", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
    );
  }

  Widget _buildCloudSyncStatusBadge() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: const Color(0xFF3A506B), borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          const Icon(Icons.sync, color: Colors.greenAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("LIVE FIRESTORE DATABASE CHANNEL ACTIVE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                Text("Last Sync Ingestion Time: $remoteLastUpdated", style: const TextStyle(color: Colors.white60, fontSize: 10)),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildRemotePatientIdentifierCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: Colors.white12), borderRadius: BorderRadius.circular(8)),
      child: const Row(
        children: [
          CircleAvatar(backgroundColor: Colors.white10, child: Icon(Icons.person, color: Colors.white70)),
          SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("PATIENT SECURE RECOGNITION ID", style: TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold)),
              Text("UNILAG_BME_2026_01", style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildRemoteAlarmBanner(bool critical) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: critical ? const Color(0xFF5C1322) : const Color(0xFF113F24),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: critical ? Colors.red : Colors.green, width: 1.5)
      ),
      child: Row(
        children: [
          Icon(critical ? Icons.gpp_bad : Icons.gpp_good, color: critical ? Colors.redAccent : Colors.greenAccent, size: 32),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(critical ? "CRITICAL CRISIS THREAT DETECTED" : "PATIENT STATUS STABLE", style: TextStyle(color: critical ? Colors.redAccent : Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 2),
                Text(critical ? "Patient oxygen drop matches sickle cell crisis markers. Initiate clinical check protocol immediately." : "Monitoring telemetry continuous. All sensor nodes returning optimal values.", style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildRemoteMetricCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xFF0B132B), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color, fontFamily: 'Courier')),
        ],
      ),
    );
  }
}