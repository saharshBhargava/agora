"""Reasoning-model transport independent of web search providers."""
import json

import httpx

from app.price_search import SearchError


def _schema(value):
    if isinstance(value, list):
        return [_schema(v) for v in value]
    if isinstance(value, dict):
        return {k: v.lower() if k == 'type' and isinstance(v, str) else _schema(v) for k, v in value.items()}
    return value


async def openai_generate(settings, client, body):
    messages = [{'role': 'system', 'content': '\n'.join(p['text'] for p in body['systemInstruction']['parts'])}]
    for content in body['contents']:
        if '_openai_message' in content:
            messages.append(content['_openai_message'])
            continue
        for part in content['parts']:
            if 'functionResponse' in part:
                reply = part['functionResponse']
                messages.append({'role': 'tool', 'tool_call_id': reply['id'],
                                 'content': json.dumps(reply['response'])})
            elif 'text' in part:
                messages.append({'role': 'user', 'content': part['text']})
    headers = {}
    if settings.openai_api_key:
        headers['Authorization'] = 'Bearer ' + settings.openai_api_key.get_secret_value()
    try:
        async with client.stream('POST', settings.openai_base_url.rstrip('/')+'/chat/completions',
                                 headers=headers, json={
                                     'model': settings.openai_model, 'messages': messages, 'stream': False,
                                     'tools': [{'type': 'function', 'function': _schema(t)}
                                               for t in body['tools'][0]['functionDeclarations']],
                                     'tool_choice': 'auto', 'max_tokens': 2048},
                                 timeout=35, follow_redirects=False) as response:
            if response.status_code != 200:
                raise SearchError('research_model_unavailable')
            raw = bytearray()
            async for chunk in response.aiter_bytes():
                raw.extend(chunk)
                if len(raw) > 1_000_000:
                    raise SearchError('research_invalid_response')
        choice = json.loads(raw)['choices'][0]
        message = choice['message']
        if choice['finish_reason'] not in ('stop', 'tool_calls') or message['role'] != 'assistant':
            raise ValueError()
        parts = []
        if isinstance(message.get('content'), str) and message['content']:
            parts.append({'text': message['content']})
        calls = message.get('tool_calls') or []
        if not isinstance(calls, list) or len(calls) > 4:
            raise ValueError()
        ids = set()
        for call in calls:
            if (call['type'] != 'function' or not isinstance(call['id'], str) or not call['id']
                    or len(call['id']) > 200 or call['id'] in ids):
                raise ValueError()
            ids.add(call['id'])
            function = call['function']
            parts.append({'functionCall': {'name': function['name'], 'id': call['id'],
                                           'args': json.loads(function['arguments'])}})
        if not parts:
            raise ValueError()
        return {'finishReason': 'STOP', 'content': {'role': 'model', 'parts': parts, '_openai_message': message}}
    except httpx.HTTPError as error:
        raise SearchError('research_model_unavailable') from error
    except (ValueError, TypeError, KeyError, IndexError) as error:
        raise SearchError('research_invalid_response') from error
