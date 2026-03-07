import 'dart:io';
void main() async {
  // Using a more minimalist, high-quality modern health icon
  final result = await Process.run('powershell', [
    '-Command', 
    'Invoke-WebRequest -Uri "https://cdn-icons-png.flaticon.com/512/2382/2382461.png" -OutFile "assets/icon/icon.png"'
  ]);
  if (result.exitCode == 0) print('Modern icon downloaded.');
}
