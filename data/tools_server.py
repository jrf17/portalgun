#!/usr/bin/env python3
"""
Tools Documentation Server with Dotfile Installer
Serves static files and handles dotfile installation via API
"""

from flask import Flask, send_from_directory, request, jsonify
import os
import shutil
import json
import subprocess

app = Flask(__name__)

DOCS_DIR = '/opt/tools-docs'
DOTFILES_DIR = os.path.join(DOCS_DIR, 'dotfiles')
HOME_DIR = os.path.expanduser('~')

@app.route('/')
def index():
    return send_from_directory(DOCS_DIR, 'index.html')

@app.route('/<path:path>')
def static_files(path):
    return send_from_directory(DOCS_DIR, path)

@app.route('/api/install-dotfile', methods=['POST'])
def install_dotfile():
    try:
        data = request.json
        dotfile_id = data.get('id')

        # Load manifest
        manifest_path = os.path.join(DOTFILES_DIR, 'manifest.json')
        with open(manifest_path, 'r') as f:
            manifest = json.load(f)

        # Find the dotfile
        dotfile = None
        for df in manifest['dotfiles']:
            if df['id'] == dotfile_id:
                dotfile = df
                break

        if not dotfile:
            return jsonify({'success': False, 'error': 'Dotfile not found'}), 404

        # Source and target paths
        source = os.path.join(DOTFILES_DIR, dotfile['file'])
        target = dotfile['target'].replace('~', HOME_DIR)

        # Create target directory if needed
        target_dir = os.path.dirname(target)
        if target_dir and not os.path.exists(target_dir):
            os.makedirs(target_dir, exist_ok=True)

        # Backup existing file if it exists
        if os.path.exists(target):
            backup = target + '.backup'
            shutil.copy2(target, backup)

        # Copy the dotfile
        shutil.copy2(source, target)

        return jsonify({
            'success': True,
            'message': f'Installed {dotfile["name"]} to {dotfile["target"]}',
            'backup': os.path.exists(target + '.backup')
        })

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/dotfiles', methods=['GET'])
def list_dotfiles():
    try:
        manifest_path = os.path.join(DOTFILES_DIR, 'manifest.json')
        with open(manifest_path, 'r') as f:
            return jsonify(json.load(f))
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/edit-dotfile', methods=['POST'])
def edit_dotfile():
    try:
        data = request.json
        dotfile_id = data.get('id')

        # Load manifest
        manifest_path = os.path.join(DOTFILES_DIR, 'manifest.json')
        with open(manifest_path, 'r') as f:
            manifest = json.load(f)

        # Find the dotfile
        dotfile = None
        for df in manifest['dotfiles']:
            if df['id'] == dotfile_id:
                dotfile = df
                break

        if not dotfile:
            return jsonify({'success': False, 'error': 'Dotfile not found'}), 404

        # Target path
        target = dotfile['target'].replace('~', HOME_DIR)

        # Set display for GUI apps
        env = os.environ.copy()
        env['DISPLAY'] = ':0'

        # Try different terminal emulators
        terminals = [
            ['kitty', '-e', 'nvim', target],
            ['qterminal', '-e', f'nvim {target}'],
            ['gnome-terminal', '--', 'nvim', target],
            ['xfce4-terminal', '-e', f'nvim {target}'],
            ['konsole', '-e', 'nvim', target],
            ['xterm', '-e', f'nvim {target}'],
        ]

        for term_cmd in terminals:
            try:
                subprocess.Popen(term_cmd, start_new_session=True, env=env)
                return jsonify({'success': True, 'message': f'Opened {target} in nvim'})
            except FileNotFoundError:
                continue

        return jsonify({'success': False, 'error': 'No terminal emulator found'}), 500

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

ZELLIJ_DIR = os.path.join(DOTFILES_DIR, 'zellij')
CUSTOM_HOTKEYS_DIR = os.path.join(ZELLIJ_DIR, 'custom')
TMUX_DIR = os.path.join(DOTFILES_DIR, 'tmux')
CUSTOM_TMUX_DIR = os.path.join(TMUX_DIR, 'custom')

# Zellij preset configs
ZELLIJ_PRESETS = {
    'p3ta': 'zellij_p3ta.kdl',
    'default': 'zellij_default.kdl'
}

ZELLIJ_HOTKEY_PRESETS = {
    'p3ta': 'hotkeys_p3ta.kdl',
    'default': 'hotkeys_default.kdl'
}

# Tmux theme presets
TMUX_THEMES = {
    'catppuccin-mocha': 'tmux_catppuccin_mocha.conf',
    'dracula': 'tmux_dracula.conf',
    'nord': 'tmux_nord.conf',
    'gruvbox': 'tmux_gruvbox.conf',
    'tokyo-night': 'tmux_tokyo_night.conf'
}

TMUX_HOTKEY_PRESETS = {
    'p3ta': 'tmux_hotkeys_p3ta.conf',
    'default': 'tmux_hotkeys_default.conf'
}

@app.route('/api/install-config', methods=['POST'])
def install_config():
    """Install zshrc or zellij config"""
    try:
        data = request.json
        config_type = data.get('type')  # zshrc, zellij-config, zellij-hotkeys
        config_id = data.get('id')

        if config_type == 'zshrc':
            # Use existing dotfile logic
            manifest_path = os.path.join(DOTFILES_DIR, 'manifest.json')
            with open(manifest_path, 'r') as f:
                manifest = json.load(f)

            dotfile = None
            for df in manifest['dotfiles']:
                if df['id'] == config_id:
                    dotfile = df
                    break

            if not dotfile:
                return jsonify({'success': False, 'error': 'Config not found'}), 404

            source = os.path.join(DOTFILES_DIR, dotfile['file'])
            target = dotfile['target'].replace('~', HOME_DIR)

        elif config_type == 'zellij-config':
            if config_id not in ZELLIJ_PRESETS:
                return jsonify({'success': False, 'error': 'Unknown preset'}), 404

            zellij_config_dir = os.path.join(HOME_DIR, '.config', 'zellij')

            # For "default", remove custom files to get true vanilla Zellij
            if config_id == 'default':
                for item in ['config.kdl', 'layouts', 'themes.kdl']:
                    item_path = os.path.join(zellij_config_dir, item)
                    if os.path.isfile(item_path):
                        os.remove(item_path)
                    elif os.path.isdir(item_path):
                        shutil.rmtree(item_path)
                # Clear cache
                cache_dir = os.path.join(HOME_DIR, '.cache', 'zellij')
                if os.path.exists(cache_dir):
                    shutil.rmtree(cache_dir)
                return jsonify({
                    'success': True,
                    'message': 'Vanilla Zellij restored (config removed)',
                    'backup': False
                })

            # For "p3ta", copy config AND extra files (layouts, themes, scripts)
            if config_id == 'p3ta':
                p3ta_files_dir = os.path.join(ZELLIJ_DIR, 'p3ta_files')
                # Copy layouts
                src_layouts = os.path.join(p3ta_files_dir, 'layouts')
                dst_layouts = os.path.join(zellij_config_dir, 'layouts')
                if os.path.exists(src_layouts):
                    if os.path.exists(dst_layouts):
                        shutil.rmtree(dst_layouts)
                    shutil.copytree(src_layouts, dst_layouts)
                # Copy themes.kdl
                src_themes = os.path.join(p3ta_files_dir, 'themes.kdl')
                if os.path.exists(src_themes):
                    shutil.copy2(src_themes, os.path.join(zellij_config_dir, 'themes.kdl'))
                # Copy scripts
                src_scripts = os.path.join(p3ta_files_dir, 'scripts')
                dst_scripts = os.path.join(zellij_config_dir, 'scripts')
                if os.path.exists(src_scripts):
                    if os.path.exists(dst_scripts):
                        shutil.rmtree(dst_scripts)
                    shutil.copytree(src_scripts, dst_scripts)
                    # Make scripts executable
                    for script in os.listdir(dst_scripts):
                        os.chmod(os.path.join(dst_scripts, script), 0o755)
                # Copy plugins (zjstatus)
                src_plugins = os.path.join(p3ta_files_dir, 'plugins')
                dst_plugins = os.path.join(zellij_config_dir, 'plugins')
                if os.path.exists(src_plugins):
                    os.makedirs(dst_plugins, exist_ok=True)
                    for plugin in os.listdir(src_plugins):
                        shutil.copy2(os.path.join(src_plugins, plugin), dst_plugins)

            source = os.path.join(ZELLIJ_DIR, ZELLIJ_PRESETS[config_id])
            target = os.path.join(zellij_config_dir, 'config.kdl')

        elif config_type == 'zellij-hotkeys':
            # Check if it's a custom config or preset
            if config_id.startswith('custom_'):
                custom_name = config_id.replace('custom_', '')
                source = os.path.join(CUSTOM_HOTKEYS_DIR, f'{custom_name}.kdl')
            elif config_id in ZELLIJ_HOTKEY_PRESETS:
                source = os.path.join(ZELLIJ_DIR, ZELLIJ_HOTKEY_PRESETS[config_id])
            else:
                return jsonify({'success': False, 'error': 'Unknown hotkey preset'}), 404
            target = os.path.join(HOME_DIR, '.config', 'zellij', 'config.kdl')

        elif config_type == 'tmux-theme':
            if config_id not in TMUX_THEMES:
                return jsonify({'success': False, 'error': 'Unknown tmux theme'}), 404
            source = os.path.join(TMUX_DIR, TMUX_THEMES[config_id])
            target = os.path.join(HOME_DIR, '.tmux.conf')

        elif config_type == 'tmux-hotkeys':
            if config_id.startswith('custom_'):
                custom_name = config_id.replace('custom_', '')
                source = os.path.join(CUSTOM_TMUX_DIR, f'{custom_name}.conf')
            elif config_id in TMUX_HOTKEY_PRESETS:
                source = os.path.join(TMUX_DIR, TMUX_HOTKEY_PRESETS[config_id])
            else:
                return jsonify({'success': False, 'error': 'Unknown tmux hotkey preset'}), 404
            target = os.path.join(HOME_DIR, '.tmux.conf')

        else:
            return jsonify({'success': False, 'error': 'Invalid config type'}), 400

        # Check source exists
        if not os.path.exists(source):
            return jsonify({'success': False, 'error': f'Source file not found: {source}'}), 404

        # Create target directory
        target_dir = os.path.dirname(target)
        if target_dir and not os.path.exists(target_dir):
            os.makedirs(target_dir, exist_ok=True)

        # Backup existing
        if os.path.exists(target):
            backup = target + '.backup'
            shutil.copy2(target, backup)

        # Copy config
        shutil.copy2(source, target)

        # If tmux config, remove old theme plugins and run TPM install
        tpm_message = ''
        if config_type in ['tmux-theme', 'tmux-hotkeys']:
            # Remove all possible theme plugin folders to prevent conflicts
            # catppuccin/tmux, dracula/tmux, nordtheme/tmux all use 'tmux'
            # egel/tmux-gruvbox uses 'tmux-gruvbox'
            # janoamaral/tokyo-night-tmux uses 'tokyo-night-tmux'
            theme_plugin_dirs = [
                os.path.join(HOME_DIR, '.tmux/plugins/tmux'),
                os.path.join(HOME_DIR, '.tmux/plugins/tmux-gruvbox'),
                os.path.join(HOME_DIR, '.tmux/plugins/tokyo-night-tmux')
            ]
            for theme_plugin_dir in theme_plugin_dirs:
                if os.path.exists(theme_plugin_dir):
                    shutil.rmtree(theme_plugin_dir)

            tpm_path = os.path.join(HOME_DIR, '.tmux/plugins/tpm/bin/install_plugins')
            if os.path.exists(tpm_path):
                try:
                    subprocess.run([tpm_path], capture_output=True, timeout=120)
                    tpm_message = ' (theme installed)'
                except:
                    tpm_message = ' (run prefix+I to install theme)'

        return jsonify({
            'success': True,
            'message': f'Installed to {target}{tpm_message}',
            'backup': os.path.exists(target + '.backup')
        })

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/edit-file', methods=['POST'])
def edit_file():
    """Open a file in nvim"""
    try:
        data = request.json
        target = data.get('target', '').replace('~', HOME_DIR)

        if not target:
            return jsonify({'success': False, 'error': 'No target specified'}), 400

        # Set display for GUI apps
        env = os.environ.copy()
        env['DISPLAY'] = ':0'

        # Try different terminal emulators
        terminals = [
            ['kitty', '-e', 'nvim', target],
            ['qterminal', '-e', f'nvim {target}'],
            ['gnome-terminal', '--', 'nvim', target],
            ['xfce4-terminal', '-e', f'nvim {target}'],
            ['konsole', '-e', 'nvim', target],
            ['xterm', '-e', f'nvim {target}'],
        ]

        for term_cmd in terminals:
            try:
                subprocess.Popen(term_cmd, start_new_session=True, env=env)
                return jsonify({'success': True, 'message': f'Opened {target} in nvim'})
            except FileNotFoundError:
                continue

        return jsonify({'success': False, 'error': 'No terminal emulator found'}), 500

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/save-hotkeys', methods=['POST'])
def save_hotkeys():
    """Save custom hotkeys and generate zellij config"""
    try:
        data = request.json
        name = data.get('name', '').strip()
        hotkeys = data.get('hotkeys', {})

        if not name:
            return jsonify({'success': False, 'error': 'Name required'}), 400

        # Sanitize name
        safe_name = ''.join(c for c in name if c.isalnum() or c in '-_').lower()

        # Ensure custom dir exists
        os.makedirs(CUSTOM_HOTKEYS_DIR, exist_ok=True)

        # Generate zellij KDL config
        kdl_config = generate_zellij_kdl(hotkeys)

        # Save to custom dir
        config_path = os.path.join(CUSTOM_HOTKEYS_DIR, f'{safe_name}.kdl')
        with open(config_path, 'w') as f:
            f.write(kdl_config)

        # Also install to user's config
        target_dir = os.path.join(HOME_DIR, '.config', 'zellij')
        os.makedirs(target_dir, exist_ok=True)
        target = os.path.join(target_dir, 'config.kdl')

        # Backup existing
        if os.path.exists(target):
            shutil.copy2(target, target + '.backup')

        shutil.copy2(config_path, target)

        return jsonify({
            'success': True,
            'message': f'Saved as {safe_name} and installed',
            'config_name': safe_name
        })

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

def generate_zellij_kdl(hotkeys):
    """Generate zellij config KDL from hotkey mapping"""
    # Default values if not specified
    defaults = {
        'split-right': 'n',
        'split-down': 'm',
        'close-pane': 'x',
        'fullscreen': 'z',
        'float': '!',
        'new-tab': 'c',
        'close-tab': '&',
        'next-tab': 'N',
        'prev-tab': 'p',
        'rename-tab': ',',
        'move-left': 'h',
        'move-down': 'j',
        'move-up': 'k',
        'move-right': 'l',
        'resize-mode': 'r',
        'scroll-mode': '[',
        'session': 's',
        'detach': 'd'
    }

    # Merge with provided hotkeys
    keys = {**defaults, **hotkeys}

    kdl = '''// Zellij Config - Custom Hotkeys
// Generated by Config Manager

keybinds clear-defaults=true {
    normal {
        // Pane operations
        bind "Ctrl ''' + keys['split-right'] + '''" { NewPane "Right"; }
        bind "Ctrl ''' + keys['split-down'] + '''" { NewPane "Down"; }
        bind "Ctrl ''' + keys['close-pane'] + '''" { CloseFocus; }
        bind "Ctrl ''' + keys['fullscreen'] + '''" { ToggleFocusFullscreen; }
        bind "Ctrl ''' + keys['float'] + '''" { ToggleFloatingPanes; }

        // Tab operations
        bind "Ctrl ''' + keys['new-tab'] + '''" { NewTab; }
        bind "Ctrl ''' + keys['close-tab'] + '''" { CloseTab; }
        bind "Ctrl ''' + keys['next-tab'] + '''" { GoToNextTab; }
        bind "Ctrl ''' + keys['prev-tab'] + '''" { GoToPreviousTab; }
        bind "Ctrl ''' + keys['rename-tab'] + '''" { SwitchToMode "RenameTab"; }

        // Navigation
        bind "Alt ''' + keys['move-left'] + '''" { MoveFocus "Left"; }
        bind "Alt ''' + keys['move-down'] + '''" { MoveFocus "Down"; }
        bind "Alt ''' + keys['move-up'] + '''" { MoveFocus "Up"; }
        bind "Alt ''' + keys['move-right'] + '''" { MoveFocus "Right"; }

        // Mode switching
        bind "Ctrl ''' + keys['resize-mode'] + '''" { SwitchToMode "Resize"; }
        bind "Ctrl ''' + keys['scroll-mode'] + '''" { SwitchToMode "Scroll"; }
        bind "Ctrl ''' + keys['session'] + '''" { SwitchToMode "Session"; }
        bind "Ctrl ''' + keys['detach'] + '''" { Detach; }

        // Tab numbers
        bind "Ctrl 1" { GoToTab 1; }
        bind "Ctrl 2" { GoToTab 2; }
        bind "Ctrl 3" { GoToTab 3; }
        bind "Ctrl 4" { GoToTab 4; }
        bind "Ctrl 5" { GoToTab 5; }
        bind "Ctrl 6" { GoToTab 6; }
        bind "Ctrl 7" { GoToTab 7; }
        bind "Ctrl 8" { GoToTab 8; }
        bind "Ctrl 9" { GoToTab 9; }
    }

    resize {
        bind "h" "Left" { Resize "Increase Left"; }
        bind "j" "Down" { Resize "Increase Down"; }
        bind "k" "Up" { Resize "Increase Up"; }
        bind "l" "Right" { Resize "Increase Right"; }
        bind "Esc" { SwitchToMode "Normal"; }
    }

    scroll {
        bind "j" "Down" { ScrollDown; }
        bind "k" "Up" { ScrollUp; }
        bind "d" { HalfPageScrollDown; }
        bind "u" { HalfPageScrollUp; }
        bind "Esc" { SwitchToMode "Normal"; }
    }

    session {
        bind "d" { Detach; }
        bind "Esc" { SwitchToMode "Normal"; }
    }

    renametab {
        bind "Enter" { SwitchToMode "Normal"; }
        bind "Esc" { SwitchToMode "Normal"; }
    }
}

// Theme
theme "catppuccin-mocha"

// UI Options
pane_frames true
'''
    return kdl

@app.route('/api/save-tmux-hotkeys', methods=['POST'])
def save_tmux_hotkeys():
    """Save custom tmux hotkeys and generate config"""
    try:
        data = request.json
        name = data.get('name', '').strip()
        hotkeys = data.get('hotkeys', {})
        theme = data.get('theme', 'catppuccin-mocha')

        if not name:
            return jsonify({'success': False, 'error': 'Name required'}), 400

        # Sanitize name
        safe_name = ''.join(c for c in name if c.isalnum() or c in '-_').lower()

        # Ensure custom dir exists
        os.makedirs(CUSTOM_TMUX_DIR, exist_ok=True)

        # Generate tmux config
        tmux_config = generate_tmux_conf(hotkeys, theme)

        # Save to custom dir
        config_path = os.path.join(CUSTOM_TMUX_DIR, f'{safe_name}.conf')
        with open(config_path, 'w') as f:
            f.write(tmux_config)

        # Also install to user's config
        target = os.path.join(HOME_DIR, '.tmux.conf')

        # Backup existing
        if os.path.exists(target):
            shutil.copy2(target, target + '.backup')

        shutil.copy2(config_path, target)

        return jsonify({
            'success': True,
            'message': f'Saved as {safe_name} and installed',
            'config_name': safe_name
        })

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

def generate_tmux_conf(hotkeys, theme='catppuccin-mocha'):
    """Generate tmux config from hotkey mapping and theme"""
    # Default hotkeys
    defaults = {
        'split-v': '|',
        'split-h': '-',
        'kill-pane': 'x',
        'fullscreen': 'z',
        'new-window': 'c',
        'kill-window': '&',
        'next-window': 'n',
        'prev-window': 'p',
        'rename-window': ',',
        'select-left': 'h',
        'select-down': 'j',
        'select-up': 'k',
        'select-right': 'l',
        'reload': 'r',
        'copy-mode': '[',
        'list-sessions': 's',
        'detach': 'd'
    }

    keys = {**defaults, **hotkeys}

    # Theme colors
    themes = {
        'catppuccin-mocha': {
            'bg': '#1e1e2e', 'fg': '#cdd6f4', 'black': '#181825', 'gray': '#313244',
            'blue': '#89b4fa', 'magenta': '#cba6f7', 'cyan': '#89dceb',
            'green': '#a6e3a1', 'yellow': '#f9e2af', 'red': '#f38ba8'
        },
        'catppuccin-macchiato': {
            'bg': '#24273a', 'fg': '#cad3f5', 'black': '#1e2030', 'gray': '#363a4f',
            'blue': '#8aadf4', 'magenta': '#c6a0f6', 'cyan': '#91d7e3',
            'green': '#a6da95', 'yellow': '#eed49f', 'red': '#ed8796'
        },
        'dracula': {
            'bg': '#282a36', 'fg': '#f8f8f2', 'black': '#21222c', 'gray': '#44475a',
            'blue': '#8be9fd', 'magenta': '#bd93f9', 'cyan': '#8be9fd',
            'green': '#50fa7b', 'yellow': '#f1fa8c', 'red': '#ff5555'
        },
        'nord': {
            'bg': '#2e3440', 'fg': '#eceff4', 'black': '#3b4252', 'gray': '#4c566a',
            'blue': '#88c0d0', 'magenta': '#b48ead', 'cyan': '#8fbcbb',
            'green': '#a3be8c', 'yellow': '#ebcb8b', 'red': '#bf616a'
        },
        'gruvbox': {
            'bg': '#282828', 'fg': '#ebdbb2', 'black': '#1d2021', 'gray': '#3c3836',
            'blue': '#83a598', 'magenta': '#d3869b', 'cyan': '#8ec07c',
            'green': '#b8bb26', 'yellow': '#fabd2f', 'red': '#fb4934'
        },
        'tokyo-night': {
            'bg': '#1a1b26', 'fg': '#c0caf5', 'black': '#15161e', 'gray': '#414868',
            'blue': '#7aa2f7', 'magenta': '#bb9af7', 'cyan': '#7dcfff',
            'green': '#9ece6a', 'yellow': '#e0af68', 'red': '#f7768e'
        }
    }

    t = themes.get(theme, themes['catppuccin-mocha'])

    conf = f'''# ═══════════════════════════════════════════════════════════════════
# Tmux Configuration - Custom Hotkeys
# Theme: {theme}
# Generated by Config Manager
# ═══════════════════════════════════════════════════════════════════

# General Settings
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 0
set -g focus-events on
set -g set-clipboard on

# ───────────────────────────────────────────────────────────────────
# Key Bindings
# ───────────────────────────────────────────────────────────────────
# Reload config
bind {keys['reload']} source-file ~/.tmux.conf \\; display "Config reloaded!"

# Split panes
bind {keys['split-v']} split-window -h -c "#{{pane_current_path}}"
bind {keys['split-h']} split-window -v -c "#{{pane_current_path}}"

# Pane navigation (vim-style)
bind {keys['select-left']} select-pane -L
bind {keys['select-down']} select-pane -D
bind {keys['select-up']} select-pane -U
bind {keys['select-right']} select-pane -R

# Alt + h/j/k/l to switch panes (no prefix)
bind -n M-h select-pane -L
bind -n M-l select-pane -R
bind -n M-k select-pane -U
bind -n M-j select-pane -D

# Pane management
bind {keys['kill-pane']} kill-pane
bind {keys['fullscreen']} resize-pane -Z

# Window management
bind {keys['new-window']} new-window -c "#{{pane_current_path}}"
bind {keys['kill-window']} kill-window
bind {keys['next-window']} next-window
bind {keys['prev-window']} previous-window
bind {keys['rename-window']} command-prompt -I "#W" "rename-window '%%'"

# Other
bind {keys['copy-mode']} copy-mode
bind {keys['list-sessions']} choose-tree -Zs
bind {keys['detach']} detach-client

# Shift + arrow to switch windows
bind -n S-Left previous-window
bind -n S-Right next-window

# Resize panes with Prefix + H/J/K/L
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# ───────────────────────────────────────────────────────────────────
# Copy Mode (vi keys)
# ───────────────────────────────────────────────────────────────────
setw -g mode-keys vi
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-pipe-and-cancel "xclip -selection clipboard"

# ───────────────────────────────────────────────────────────────────
# Theme: {theme}
# ───────────────────────────────────────────────────────────────────
set -g status on
set -g status-interval 1
set -g status-position bottom
set -g status-justify left
set -g status-style "bg={t['bg']},fg={t['fg']}"

# Left side
set -g status-left-length 100
set -g status-left "#[fg={t['black']},bg={t['blue']},bold]  #S #[fg={t['blue']},bg={t['bg']},nobold]#[default] "

# Right side
set -g status-right-length 100
set -g status-right "#[fg={t['gray']},bg={t['bg']}]#[fg={t['fg']},bg={t['gray']}]  %H:%M #[fg={t['blue']}]#[fg={t['black']},bg={t['blue']},bold]  %d-%b "

# Window status
set -g window-status-format "#[fg={t['gray']},bg={t['bg']}]#[fg={t['fg']},bg={t['gray']}] #I: #W #[fg={t['gray']},bg={t['bg']}]"
set -g window-status-current-format "#[fg={t['magenta']},bg={t['bg']}]#[fg={t['black']},bg={t['magenta']},bold] #I: #W #[fg={t['magenta']},bg={t['bg']}]"
set -g window-status-separator ""

# Pane borders
set -g pane-border-style "fg={t['gray']}"
set -g pane-active-border-style "fg={t['blue']}"

# Messages
set -g message-style "fg={t['cyan']},bg={t['gray']},bold"

# Mode style
setw -g mode-style "fg={t['magenta']},bg={t['gray']},bold"

# Clock
setw -g clock-mode-colour "{t['blue']}"

# ═══════════════════════════════════════════════════════════════════
# TPM - Tmux Plugin Manager
# ═══════════════════════════════════════════════════════════════════
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'tmux-plugins/tmux-yank'

set -g @resurrect-capture-pane-contents 'on'
set -g @continuum-restore 'on'
set -g @continuum-save-interval '10'

# Initialize TPM
run '~/.tmux/plugins/tpm/tpm'
'''
    return conf

if __name__ == '__main__':
    # Ensure directories exist
    os.makedirs(ZELLIJ_DIR, exist_ok=True)
    os.makedirs(CUSTOM_HOTKEYS_DIR, exist_ok=True)
    os.makedirs(TMUX_DIR, exist_ok=True)
    os.makedirs(CUSTOM_TMUX_DIR, exist_ok=True)

    print(f"Serving tools documentation from {DOCS_DIR}")
    print(f"Dotfiles directory: {DOTFILES_DIR}")
    print(f"Zellij configs: {ZELLIJ_DIR}")
    print(f"Tmux configs: {TMUX_DIR}")
    app.run(host='0.0.0.0', port=1337, debug=False)
