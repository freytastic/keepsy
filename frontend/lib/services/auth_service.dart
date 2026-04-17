import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';

class AuthService {
  // request otp
  Future<bool> requestOtp(String email) async {
    final url = Uri.parse("${K.baseURL}/auth/otp/request");
    final response = await http.post(
      url,
      headers: {"Cntent-type": "application/json"},
      body: jsonEncode({"email": email}),
    );
    return response.statusCode == 200;
  }

  // verify otp
  Future<String?> verifyOtp(String email, String code) async {
    final url = Uri.parse("${K.baseURL}/auth/otp/verify");
    final response = await http.post(
      url,
      headers: {"Content-type": "application/json"},
      body: jsonEncode({"email": email,
                         "otp": code}),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['token'];
    }
    return null;
  }
}