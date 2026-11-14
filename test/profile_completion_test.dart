import 'package:flutter_test/flutter_test.dart';
import 'package:hakbanghero/models/character_profile.dart';
import 'package:hakbanghero/services/private_data.dart';

void main() {
  Map<String, dynamic> complete() => {
    'character_created': true,
    'gender': 'female',
    'height_cm': 170.0,
    'weight_kg': 65.0,
  };

  test('new accounts and unfinished onboarding require completion', () {
    expect(PrivateData.profileComplete({'character_created': false}), isFalse);
    expect(PrivateData.profileComplete({...complete(), 'character_created': false}), isFalse);
    expect(PrivateData.profileComplete({...complete()}..remove('character_created')), isFalse);
  });

  test('completed profiles pass for either authentication provider', () {
    for (final provider in ['google.com', 'password']) {
      expect(PrivateData.profileComplete({...complete(), 'provider': provider}), isTrue);
    }
  });

  test('a completion flag cannot bypass missing gender or measurements', () {
    for (final field in ['gender', 'height_cm', 'weight_kg']) {
      final data = complete()..remove(field);
      expect(PrivateData.profileComplete(data), isFalse, reason: field);
    }
  });

  test('measurement limits match manual onboarding, including invalid numbers', () {
    for (final height in [99, 251, double.nan, double.infinity, '170']) {
      expect(PrivateData.profileComplete({...complete(), 'height_cm': height}), isFalse);
    }
    for (final weight in [24, 301, double.nan, double.infinity, '65']) {
      expect(PrivateData.profileComplete({...complete(), 'weight_kg': weight}), isFalse);
    }
    expect(PrivateData.profileComplete({...complete(), 'height_cm': 100, 'weight_kg': 25}), isTrue);
    expect(PrivateData.profileComplete({...complete(), 'height_cm': 250, 'weight_kg': 300}), isTrue);
  });

  test('private measurements win, legacy values fill gaps, inputs stay unchanged', () {
    final user = {...complete(), 'xp': 700, 'hero_id': 'fox'};
    final body = {'weight_kg': 70.25};
    final data = PrivateData.profileData(user, body);
    expect(data['height_cm'], 170);
    expect(data['weight_kg'], 70.25);
    expect(data['hero_id'], 'fox');
    expect(data['xp'], 700);
    expect(user['weight_kg'], 65);
    expect(body, {'weight_kg': 70.25});
    expect(PrivateData.profileComplete(data), isTrue);
    expect(CharacterProfile.fromFirestore(data).bodyTier, BodyTier.normal);
  });
}
