import json
import os

def main():
    state_path = 'terraform.tfstate'
    if not os.path.exists(state_path):
        print("terraform.tfstate not found.")
        return

    with open(state_path, 'r') as f:
        state = json.load(f)

    outputs = state.get('outputs', {})
    talosconfig_out = outputs.get('talosconfig', {})
    val = talosconfig_out.get('value', {})

    if not val:
        print("No talosconfig value found in outputs.")
        return

    ca = val.get('ca_certificate')
    crt = val.get('client_certificate')
    key = val.get('client_key')

    config = f"""context: hpa-dev
contexts:
  hpa-dev:
    endpoints:
      - 192.168.122.100
    ca: {ca}
    crt: {crt}
    key: {key}
"""

    with open('talosconfig', 'w') as f:
        f.write(config)
    print("Successfully extracted and wrote talosconfig!")

if __name__ == '__main__':
    main()
