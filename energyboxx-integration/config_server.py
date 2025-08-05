#!/usr/bin/env python3
from flask import Flask, request, jsonify, send_from_directory
import json
import os

app = Flask(__name__, static_folder='static')

CONFIG_PATH = '/data/options.json'
LOG_PATH = '/var/log/energyboxx-addon.log'

@app.route('/')
def index():
    return send_from_directory(app.static_folder, 'index.html')

@app.route('/api/config', methods=['GET'])
def get_config():
    try:
        with open(CONFIG_PATH, 'r') as f:
            config = json.load(f)
        return jsonify(config)
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/config', methods=['POST'])
def update_config():
    try:
        config = request.json
        with open(CONFIG_PATH, 'w') as f:
            json.dump(config, f, indent=2)
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/logs', methods=['GET'])
def get_logs():
    try:
        if os.path.exists(LOG_PATH):
            with open(LOG_PATH, 'r') as f:
                lines = f.readlines()[-100:]
            return '<br>'.join(line.rstrip() for line in lines)
        else:
            return 'No logs found.'
    except Exception as e:
        return f'Error reading logs: {e}'

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)

