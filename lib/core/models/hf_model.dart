class HFModel {
  final String id;
  final String name;
  final String? baseModel;
  final String description;
  final int sizeMB;
  final int requiredRAM;
  final double speed;
  final double quality;
  final List<String> capabilities;
  final String modelType;
  final String fileType;
  final String? downloadFilename;
  final bool downloaded;
  final int progress; // 0-100
  final String? localPath;
  final String? downloadStatus; // 'none', 'downloading', 'paused', 'completed', 'error'
  final double? downloadSpeed; // in MB/s
  final int? downloadedBytes;
  final int? totalBytes;
  final String? errorMessage;

  HFModel({
    required this.id,
    required this.name,
    this.baseModel,
    required this.description,
    required this.sizeMB,
    this.requiredRAM = 3,
    required this.speed,
    required this.quality,
    required this.capabilities,
    this.modelType = 'gguf',
    this.fileType = 'gguf',
    this.downloadFilename,
    this.downloaded = false,
    this.progress = 0,
    this.localPath,
    this.downloadStatus = 'none',
    this.downloadSpeed,
    this.downloadedBytes,
    this.totalBytes,
    this.errorMessage,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseModel': baseModel,
    'description': description,
    'sizeMB': sizeMB,
    'requiredRAM': requiredRAM,
    'speed': speed,
    'quality': quality,
    'capabilities': capabilities,
    'modelType': modelType,
    'fileType': fileType,
    'downloadFilename': downloadFilename,
    'downloaded': downloaded,
    'progress': progress,
    'localPath': localPath,
    'downloadStatus': downloadStatus,
    'downloadSpeed': downloadSpeed,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'errorMessage': errorMessage,
  };

  factory HFModel.fromJson(Map<String, dynamic> json) => HFModel(
    id: json['id'],
    name: json['name'],
    baseModel: json['baseModel'],
    description: json['description'],
    sizeMB: json['sizeMB'],
    requiredRAM: json['requiredRAM'] ?? 3,
    speed: (json['speed'] as num).toDouble(),
    quality: (json['quality'] as num).toDouble(),
    capabilities: List<String>.from(json['capabilities']),
    modelType: json['modelType'] ?? 'gguf',
    fileType: json['fileType'] ?? 'gguf',
    downloadFilename: json['downloadFilename'],
    downloaded: json['downloaded'] ?? false,
    progress: json['progress'] ?? 0,
    localPath: json['localPath'],
    downloadStatus: json['downloadStatus'] ?? 'none',
    downloadSpeed: (json['downloadSpeed'] as num?)?.toDouble(),
    downloadedBytes: json['downloadedBytes'],
    totalBytes: json['totalBytes'],
    errorMessage: json['errorMessage'],
  );

  HFModel copyWith({
    String? id,
    String? name,
    String? baseModel,
    String? description,
    int? sizeMB,
    int? requiredRAM,
    double? speed,
    double? quality,
    List<String>? capabilities,
    String? modelType,
    String? fileType,
    String? downloadFilename,
    bool? downloaded,
    int? progress,
    String? localPath,
    String? downloadStatus,
    double? downloadSpeed,
    int? downloadedBytes,
    int? totalBytes,
    String? errorMessage,
    bool clearError = false,
  }) => HFModel(
    id: id ?? this.id,
    name: name ?? this.name,
    baseModel: baseModel ?? this.baseModel,
    description: description ?? this.description,
    sizeMB: sizeMB ?? this.sizeMB,
    requiredRAM: requiredRAM ?? this.requiredRAM,
    speed: speed ?? this.speed,
    quality: quality ?? this.quality,
    capabilities: capabilities ?? this.capabilities,
    modelType: modelType ?? this.modelType,
    fileType: fileType ?? this.fileType,
    downloadFilename: downloadFilename ?? this.downloadFilename,
    downloaded: downloaded ?? this.downloaded,
    progress: progress ?? this.progress,
    localPath: localPath ?? this.localPath,
    downloadStatus: downloadStatus ?? this.downloadStatus,
    downloadSpeed: downloadSpeed ?? this.downloadSpeed,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );
}
