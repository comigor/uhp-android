import 'package:flutter_test/flutter_test.dart';
import 'package:uhp_android/main.dart';

void main() {
  test('extracts assistant output text in order', () {
    final payload = <String, dynamic>{
      'output': <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'assistant',
          'content': <Map<String, String>>[
            <String, String>{'text': 'Hello'},
            <String, String>{'text': 'world'},
          ],
        },
        <String, dynamic>{
          'role': 'tool',
          'content': <Map<String, String>>[
            <String, String>{'text': 'ignore me'},
          ],
        },
        <String, dynamic>{
          'role': 'assistant',
          'content': <Map<String, String>>[
            <String, String>{'text': 'again'},
          ],
        },
      ],
    };

    expect(extractAssistantText(payload), 'Hello\nworld\nagain');
  });

  test('builds continuation request body with previous response id', () {
    final body = buildResponseRequestBody(
      const ResponseDraft(
        input: 'continue this',
        harnessId: 'harness-1',
        previousResponseId: 'resp-1',
      ),
    );

    expect(body, <String, dynamic>{
      'input': 'continue this',
      'stream': false,
      'metadata': <String, dynamic>{'harness_id': 'harness-1'},
      'previous_response_id': 'resp-1',
    });
  });
}
