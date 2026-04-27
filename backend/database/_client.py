import hashlib
import json
import logging
import os
import uuid

import firebase_admin
from firebase_admin import credentials as firebase_credentials
from google.cloud import firestore

if os.environ.get('SERVICE_ACCOUNT_JSON'):
    try:
        service_account_info = json.loads(os.environ['SERVICE_ACCOUNT_JSON'])
    except json.JSONDecodeError as e:
        logging.error('SERVICE_ACCOUNT_JSON inválido — verifique as variáveis de ambiente no Railway: %s', e)
        raise RuntimeError('SERVICE_ACCOUNT_JSON não é um JSON válido') from e
    _creds_path = '/tmp/google-credentials.json'
    with open(_creds_path, 'w') as f:
        json.dump(service_account_info, f)
    os.environ.setdefault('GOOGLE_APPLICATION_CREDENTIALS', _creds_path)

# Inicializa Firebase Admin SDK (necessário para auth.verify_id_token no desktop)
try:
    firebase_admin.get_app()
except ValueError:
    # App ainda não inicializado — usa GOOGLE_APPLICATION_CREDENTIALS (já setado acima)
    try:
        if os.environ.get('GOOGLE_APPLICATION_CREDENTIALS'):
            cred = firebase_credentials.Certificate(os.environ['GOOGLE_APPLICATION_CREDENTIALS'])
            firebase_admin.initialize_app(cred)
        else:
            firebase_admin.initialize_app()  # usa ADC
    except Exception as e:
        logging.warning('Firebase Admin SDK não pôde ser inicializado: %s', e)

_db = None


def _get_db():
    global _db
    if _db is None:
        try:
            _db = firestore.Client()
        except Exception as e:
            logging.warning('Firestore client unavailable: %s', e)
    return _db


class _LazyDB:
    """Proxy that defers Firestore init until first attribute access."""

    def __getattr__(self, name):
        client = _get_db()
        if client is None:
            raise RuntimeError('Firestore client not initialised — check Google credentials')
        return getattr(client, name)


db = _LazyDB()


def get_users_uid():
    users_ref = db.collection('users')
    return [str(doc.id) for doc in users_ref.stream()]


def document_id_from_seed(seed: str) -> uuid.UUID:
    """Avoid repeating the same data"""
    seed_hash = hashlib.sha256(seed.encode('utf-8')).digest()
    generated_uuid = uuid.UUID(bytes=seed_hash[:16], version=4)
    return str(generated_uuid)
