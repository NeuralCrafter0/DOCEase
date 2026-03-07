class Doctor {
  final String id;
  final String title;
  final String name;
  final String email; // New field
  final String age;
  final String mobileNumber;
  final String specialty;
  final String clinicName;
  final String practiceMode;
  final String? profileImageUrl;

  Doctor({
    required this.id,
    required this.title,
    required this.name,
    required this.email,
    required this.age,
    required this.mobileNumber,
    required this.specialty,
    required this.clinicName,
    required this.practiceMode,
    this.profileImageUrl,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'name': name,
    'email': email,
    'age': age,
    'mobileNumber': mobileNumber,
    'specialty': specialty,
    'clinicName': clinicName,
    'practiceMode': practiceMode,
    'profileImageUrl': profileImageUrl,
  };

  factory Doctor.fromJson(Map<String, dynamic> json) => Doctor(
    id: json['id'] ?? '',
    title: json['title'] ?? 'MR',
    name: json['name'] ?? '',
    email: json['email'] ?? '',
    age: json['age'] ?? '',
    mobileNumber: json['mobileNumber'] ?? '',
    specialty: json['specialty'] ?? '',
    clinicName: json['clinicName'] ?? '',
    practiceMode: json['practiceMode'] ?? 'Solo Practice',
    profileImageUrl: json['profileImageUrl'],
  );
}
