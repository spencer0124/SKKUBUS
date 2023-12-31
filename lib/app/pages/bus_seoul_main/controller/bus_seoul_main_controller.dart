import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:skkumap/admob/ad_helper.dart';
import 'package:skkumap/app/data/model/bus_data_model.dart';
import 'package:skkumap/app/data/repository/bus_data_repository.dart';

/*
라이프사이클 감지 -> 화면이 다시 보일 때마다 데이터 갱신
*/
class SeoulMainLifeCycle extends GetxController with WidgetsBindingObserver {
  BusDataController busDataController = Get.find<BusDataController>();

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void onClose() {
    super.onClose();
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      if (busDataController.refreshTime.value > 1 &&
          busDataController.preventAnimation.value == false) {
        busDataController.refreshData();
      }
    }
  }
}

/*
메인 컨트롤러
*/

class BusDataController extends GetxController
    with SingleGetTickerProviderMixin {
  RxBool waitAdFail = false.obs;
  RxBool preventAnimation = false.obs;
  late String platform;

  @override
  void onInit() async {
    super.onInit();

    // permission handler로 이전하기
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }

    // 현재 스크린 firebase에 기록

    // 현재 플랫폼 가져와서 firebase에 기록

    // getCurrentPlatform()

    // if (Platform.isAndroid) {
    //   platform = 'Android';
    // } else if (Platform.isIOS) {
    //   platform = 'IOS';
    // } else {
    //   platform = 'unknown';
    // }

    // Future.delayed(const Duration(milliseconds: 3000), () {
    //   waitAdFail.value = true;
    //   FirebaseAnalytics.instance
    //       .logEvent(name: 'alternative_ad_showed', parameters: {
    //     'platform': platform,
    //   });
    // });

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    _bannerAd = BannerAd(
      adUnitId: AdHelper.bannerAdUnitId,
      request: const AdRequest(),
      size: AdSize.banner,
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          _bannerAd = ad as BannerAd;
          isAdLoaded.value = true;
        },
        onAdFailedToLoad: (ad, err) {
          print('Failed to load a banner ad: ${err.message}');
          ad.dispose();
        },
      ),
    )..load();

    updateTime();
    fetchBusData();
    startUpdateTimer();
  }

  Future<void> onShareClicked() async {
    FirebaseAnalytics.instance.logEvent(name: 'share_clicked');
    List activeBuses =
        busDataList.where((bus) => bus.carNumber.isNotEmpty).toList();
    String activeBusDetails = activeBuses.map((bus) {
      String nextStation = getNextStation(bus.stationName);
      return '${bus.stationName} → $nextStation\n${timeDifference2(bus.eventDate)} ${'전 출발\n'.tr}';
    }).join('\n');

    await Share.share(
        '${'인사캠 셔틀버스 실시간 위치'.tr}\n[${currentTime.value} ${'기준'.tr} · ${activeBuses.length}${'대 운행 중'.tr}]\n\n$activeBusDetails\n${'스꾸버스 앱에서 편하게 정보를 받아보세요!'.tr}\nskkubus-app.kro.kr');
  }

  BannerAd? _bannerAd;
  BannerAd? get bannerAd => _bannerAd;
  RxBool isAdLoaded = false.obs;
  AnimationController? _animationController;
  AnimationController? get animationController => _animationController;

  final BusDataRepository repository;
  final currentTime = ''.obs;

  // final activeBusCount = 0.obs;
  final activeBusCount = Rx<int?>(null);
  var adLoad = false.obs;
  var busDataList = <BusData>[].obs;
  var refreshTime = 5.obs;

  final stations = [
    '정차소(인문.농구장)',
    '학생회관(인문)',
    '정문(인문-하교)',
    '혜화로터리(하차지점)',
    '혜화역U턴지점',
    '혜화역(승차장)',
    '혜화로터리(경유)',
    '맥도날드 건너편',
    '정문(인문-등교)',
    '600주년 기념관'
  ];
  var logger = Logger();

  RxBool loadingAnimation = false.obs;

  Timer? updateTimer;

  BusDataController({required this.repository});

  String getNextStation(String currentStation) {
    int currentIndex = stations.indexOf(currentStation);
    if (currentIndex != -1 && currentIndex < stations.length - 1) {
      return stations[currentIndex + 1]; // Returns the next station
    } else if (currentIndex == stations.length - 1) {
      return stations[0]; // If it's the last station, return the first one
    } else {
      return 'null'; // If the currentStation is not found in the list
    }
  }

  String getStationMessage(int index) {
    var currentStation = busDataList[index].stationName;
    var currentIndex = stations.indexOf(currentStation);

    for (var i = currentIndex - 1; i >= 0; i--) {
      if (busDataList[i].carNumber.isNotEmpty) {
        return '개 정거장 남음'.trPluralParams('개 정거장 남음s', currentIndex - i,
            {'count': (currentIndex - i).toString()});
      }
    }

    return '도착 정보 없음'.tr;
  }

  String timeDifference(String eventDate) {
    DateFormat format = DateFormat('yyyy-MM-dd HH:mm:ss');
    DateTime eventDateTime;
    try {
      eventDateTime = format.parse(eventDate);
    } catch (e) {
      print("Error parsing date: $e");
      return "Invalid Date";
    }

    final duration = DateTime.now().difference(eventDateTime);

    if (duration.inSeconds < 15) {
      return '도착 혹은 출발'.tr;
    } else if (duration.inDays > 1) {
      return '하루 이상 전 정류장 떠남'.tr;
    } else {
      return '${duration.inMinutes}${'분'.tr}\u{00A0}${duration.inSeconds % 60}${'초'.tr}\u{00A0}${'전 정류장 떠남'.tr}';
    }
  }

  String timeDifference2(String eventDate) {
    DateFormat format = DateFormat('yyyy-MM-dd HH:mm:ss');
    DateTime eventDateTime;
    try {
      eventDateTime = format.parse(eventDate);
    } catch (e) {
      print("Error parsing date: $e");
      return "Invalid Date";
    }

    // print('Now: ${DateTime.now()}');
    // print('Event date: $eventDateTime');
    final duration = DateTime.now().difference(eventDateTime);

    return '${duration.inMinutes}분 ${duration.inSeconds % 60}초';
  }

  int timeDifference3(String eventDate) {
    DateFormat format = DateFormat('yyyy-MM-dd HH:mm:ss');
    DateTime eventDateTime;
    try {
      eventDateTime = format.parse(eventDate);
    } catch (e) {
      print("Error parsing date: $e");
      return 0;
    }

    // print('Now: ${DateTime.now()}');
    // print('Event date: $eventDateTime');
    final duration = DateTime.now().difference(eventDateTime);

    return duration.inSeconds;
  }

  @override
  void onClose() {
    _bannerAd?.dispose();
    updateTimer?.cancel();
    super.onClose();
  }

  void startUpdateTimer() {
    updateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (refreshTime.value > 0) {
        refreshTime.value--;
      } else {
        refreshData();
        // Future.delayed(const Duration(milliseconds: 1000), () {});
      }
    });
  }

  void refreshData() {
    updateTimer?.cancel();
    fetchBusData();
    updateTime();

    _animationController?.reset();
    _animationController?.forward();

    Future.delayed(const Duration(milliseconds: 1000), () {
      refreshTime.value = 5;
      startUpdateTimer();
    });
  }

  Future<void> waitanimation() async {
    await Future.delayed(const Duration(seconds: 2));
    loadingAnimation.value = false;
  }

  void fetchBusData() async {
    try {
      var data = await repository.getBusData();
      busDataList.assignAll(data);
      updateActiveBusCount();
    } catch (e) {
      print('Failed to fetch bus data: $e');
    }
  }

  void updateTime() {
    final format = DateFormat.jm(); // Output: hh:mm AM/PM
    currentTime.value = format.format(DateTime.now());
  }

  void updateActiveBusCount() {
    activeBusCount.value = getActiveBusCount(busDataList);
  }

  int getActiveBusCount(List<BusData> busDataList) {
    return busDataList.where((bus) => bus.carNumber.isNotEmpty).length;
  }
}
