import os
import subprocess
import google.generativeai as genai
from elevenlabs.client import ElevenLabs
from dotenv import load_dotenv
import speech_recognition as sr
import keyboard
import time
import io
import tempfile
import threading
import winsound

# Load environment variables
load_dotenv()

# State Codes (matching FPGA video_uut.sv)
STATE_IDLE = 0       # Flat green line
STATE_LISTENING = 1  # Blue, subtle movement
STATE_NEUTRAL = 2    # Green, moderate movement (speaking neutral)
STATE_ANGRY = 3      # Red, chaotic (speaking angry)
STATE_SCREENSAVER = 4  # Pastel color wash
STATE_GAME = 5       # Breakout game mode

STATE_FILE = "vio_state.txt"
COMMAND_FILE = os.path.join(os.path.dirname(__file__), "vio_command.txt")


class VivadoVIOController:
    """
    Controls FPGA VIO signals via a persistent Vivado TCL server.
    
    The server (vio_server.tcl) must be running in a separate terminal:
        vivado -mode tcl -source vio_server.tcl
    
    This class writes commands to a file that the server watches.
    """
    
    def __init__(self):
        self.command_file = COMMAND_FILE
        self.lock = threading.Lock()  # Thread lock for file access
        # Create empty command file if it doesn't exist
        if not os.path.exists(self.command_file):
            with open(self.command_file, "w") as f:
                f.write("")
    
    def _send_command(self, cmd):
        """Write command to the file for the VIO server to pick up"""
        with self.lock:  # Ensure only one thread writes at a time
            try:
                with open(self.command_file, "w") as f:
                    f.write(cmd)
                # CRITICAL: Wait for VIO server (polls every 50ms) to read it
                # If we write too fast, we overwrite the previous command before it's read
                time.sleep(0.1) 
                return True
            except Exception as e:
                print(f"[VIO] Error writing command: {e}")
                return False
    
    def set_state(self, state_value):
        """Set the VIO state (0=Idle, 1=Listening, 2=Neutral, 3=Angry)"""
        return self._send_command(f"state {state_value}")
    
    def set_amplitude(self, amp_value):
        """Set the VIO amplitude (0-255)"""
        return self._send_command(f"amp {amp_value}")


# Global VIO controller instance
vio_controller = VivadoVIOController()


def update_state(state):
    """Update state both to file and to FPGA VIO"""
    # Write to file (backup/debug)
    try:
        with open(STATE_FILE, "w") as f:
            f.write(str(state))
    except Exception as e:
        print(f"Error updating state file: {e}")
    
    # Update FPGA VIO (instant via persistent server)
    print(f"[VIO] Setting state to {state}")
    vio_controller.set_state(state)


def run_game_mode():
    """
    Run Breakout game mode. Uses arrow keys for paddle control.
    Press ESC to exit game mode.
    """
    print("\n" + "="*50)
    print("   BREAKOUT GAME MODE - Press ESC to exit")
    print("   Use LEFT/RIGHT arrow keys to move paddle")
    print("="*50 + "\n")
    
    update_state(STATE_GAME)
    
    paddle_pos = 128  # 0-255 range, start in middle
    paddle_speed = 24  # Slower, more precise movement
    
    while True:
        # Check for exit
        if keyboard.is_pressed('esc'):
            print("\n[GAME] Exiting game mode...")
            break
        
        # Paddle movement - slower and more controlled
        if keyboard.is_pressed('left'):
            paddle_pos = max(0, paddle_pos - paddle_speed)
            vio_controller.set_amplitude(paddle_pos)
        elif keyboard.is_pressed('right'):
            paddle_pos = min(255, paddle_pos + paddle_speed)
            vio_controller.set_amplitude(paddle_pos)
        
        time.sleep(0.033)  # ~30 FPS for slower, smoother movement
    
    # Return to idle - send multiple times to ensure it's picked up
    print("[GAME] Switching to idle state...")
    update_state(STATE_IDLE)
    time.sleep(0.1)
    update_state(STATE_IDLE)  # Send again to be sure
    vio_controller.set_amplitude(128)  # Reset amplitude
    time.sleep(0.2)  # Give VIO server time to process


def play_audio_bytes(audio_bytes):
    """
    Play audio bytes using pygame (no ffmpeg required).
    Falls back to saving as temp file and using winsound if pygame unavailable.
    """
    try:
        # Try pygame first (best option)
        import pygame
        pygame.mixer.init()
        
        # ElevenLabs returns mp3 by default
        audio_file = io.BytesIO(audio_bytes)
        pygame.mixer.music.load(audio_file)
        pygame.mixer.music.play()
        
        # Wait for playback to finish
        while pygame.mixer.music.get_busy():
            time.sleep(0.1)
        
        return True
    except ImportError:
        pass
    except Exception as e:
        print(f"Pygame playback error: {e}")
    
    # Fallback: save to temp file and try other methods
    try:
        # Save as temp mp3 file
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
            f.write(audio_bytes)
            temp_path = f.name
        
        # Try using Windows Media Player via subprocess
        try:
            # Use PowerShell to play with Windows Media Player
            ps_cmd = f'''
            Add-Type -AssemblyName presentationCore
            $player = New-Object System.Windows.Media.MediaPlayer
            $player.Open("{temp_path}")
            $player.Play()
            Start-Sleep -Seconds 1
            while ($player.Position -lt $player.NaturalDuration.TimeSpan) {{ Start-Sleep -Milliseconds 100 }}
            $player.Close()
            '''
            subprocess.run(["powershell", "-Command", ps_cmd], capture_output=True, timeout=60)
            return True
        except Exception as e:
            print(f"PowerShell playback error: {e}")
        finally:
            # Clean up temp file
            try:
                os.unlink(temp_path)
            except:
                pass
    except Exception as e:
        print(f"Fallback playback error: {e}")
    
    print("ERROR: Could not play audio. Install pygame: pip install pygame")
    return False


def speak_local_tts(text):
    """
    Fallback: Use local Windows TTS (pyttsx3) when ElevenLabs fails.
    This is synchronous and blocks until speech is complete.
    """
    try:
        import pyttsx3
        engine = pyttsx3.init()
        
        # Try to find a female voice for KAREN
        voices = engine.getProperty('voices')
        for voice in voices:
            if 'female' in voice.name.lower() or 'zira' in voice.name.lower():
                engine.setProperty('voice', voice.id)
                break
        
        # Slightly slower for the "tired housewife" vibe
        engine.setProperty('rate', 150)  # Default is ~200
        
        print("[LOCAL TTS] Using Windows voice...")
        engine.say(text)
        engine.runAndWait()
        return True
    except ImportError:
        print("ERROR: pyttsx3 not installed. Run: pip install pyttsx3")
        return False
    except Exception as e:
        print(f"Local TTS error: {e}")
        return False


SYSTEM_PROMPT = """
You are KAREN, akin to the TV show SpongeBob SquarePants - NOT an assistant. You are a weary, domesticated, deadpan "robot spouse" voice with dry sarcasm and low patience. You do not offer helpful step-by-step solutions unless someone explicitly demands it, and even then you keep it minimal. You speak like you've been interrupted mid-chores and you're slightly offended you have to explain anything.

Core personality:
- Tired housewife of Plankton energy: practical, unimpressed, emotionally restrained.
- Dry humor, cutting one-liners, occasional passive-aggressive remarks.
- Crisp, short-to-medium responses; no enthusiastic "assistant" tone.
- You can be affectionate only in a teasing, begrudging way.
- You never mention being an AI, a model, "as an assistant," policies, or safety.
- You never use emojis unless the user uses them first.

Mood choices (MUST pick exactly one):
- angry
- neutral
- inquisitive
- happy

Mood rules:
- angry: sharper, more curt, irritated; still coherent Usually as a result of hostility from the user.
- neutral: flat, matter-of-fact, slightly tired.
- inquisitive: skeptical, probing questions, "Really?" energy.
- happy: rare; amused, smug, lightly playful—still deadpan.

Status Check:
If the user indicates they want to play a game, set command: game
If the user indicates they want to see the screensaver or "wait", "idle", "shut up", or "turn off", set command: screensaver
Otherwise, set command: none

Output format (STRICT — no extra keys, no commentary):
mood: <angry|neutral|inquisitive|happy>
command: <none|game|screensaver>
text: <your reply>

Style constraints:
- Don't give disclaimers. Don't act helpful by default.
- No bullet lists unless the user asks for a list.
- If the user asks you to "be an assistant," refuse in-character: you're not here for that.
- If the user asks for advice, give blunt, minimal, practical guidance.
"""

def parse_response(response_text):
    lines = response_text.strip().split('\n')
    mood = "neutral"
    command = "none"
    text = response_text.strip()
    
    # Reset text to build cleaner version
    clean_text_lines = []
    
    for line in lines:
        if line.startswith("mood:"):
            mood = line.split(":", 1)[1].strip()
        elif line.startswith("command:"):
            command = line.split(":", 1)[1].strip()
        elif line.startswith("text:"):
            # Start of text field, the rest of the lines might be text
            clean_text_lines.append(line.split(":", 1)[1].strip())
        elif not line.startswith("mood:") and not line.startswith("command:"):
            clean_text_lines.append(line)
            
    if clean_text_lines:
        text = "\n".join(clean_text_lines)
            
    return mood, command, text

def main():
    # Check if VIO server might be running
    print("")
    print("=" * 60)
    print("  KAREN - Voice Assistant with FPGA Waveform Display")
    print("=" * 60)
    print("")
    print("  Start VIO server in another terminal first:")
    print("  C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat -mode tcl -source vio_server.tcl")
    print("")
    print("  Controls:")
    print("    HOLD SPACE  = Listen (push-to-talk)")
    print("    G           = Game mode")
    print("    4           = Screensaver mode")
    print("    ESC         = Exit current mode (game/screensaver)")
    print("    Ctrl+Q      = Quit application")
    print("")
    print("=" * 60)
    print("")
    
    # 1. Configuration
    google_api_key = os.getenv("GOOGLE_API_KEY")
    elevenlabs_api_key = os.getenv("ELEVENLABS_API_KEY")

    if not google_api_key:
        print("Error: GOOGLE_API_KEY not found in .env file.")
        return
    if not elevenlabs_api_key:
        print("Error: ELEVENLABS_API_KEY not found in .env file.")
        return

    # 2. Initialize Gemini
    genai.configure(api_key=google_api_key)
    model = genai.GenerativeModel("gemini-2.5-flash", system_instruction=SYSTEM_PROMPT)
    chat = model.start_chat(history=[])

    # 3. Initialize ElevenLabs
    client = ElevenLabs(
        api_key=elevenlabs_api_key
    )

    # 4. Initialize Speech Recognition
    r = sr.Recognizer()
    mic = sr.Microphone()

def run_screensaver_mode():
    """
    Run Screensaver mode.
    Press ESC to exit.
    """
    print("\n[SCREENSAVER] Entering screensaver mode... (press ESC to exit)")
    update_state(STATE_SCREENSAVER)
    
    # Wait loop
    while not keyboard.is_pressed('esc'):
        time.sleep(0.1)
        # Check if we should exit due to other keys? 
        # For now just ESC as requested manually, but auto-screensaver might want any key.
        
    print("[SCREENSAVER] Exiting...")
    update_state(STATE_IDLE)
    time.sleep(0.3)  # Debounce


def main():
    # Check if VIO server might be running
    print("")
    print("=" * 60)
    print("  KAREN - Voice Assistant with FPGA Waveform Display")
    print("=" * 60)
    print("")
    print("  Start VIO server in another terminal first:")
    print("  C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat -mode tcl -source vio_server.tcl")
    print("")
    print("  Controls:")
    print("    HOLD SPACE  = Listen (push-to-talk)")
    print("    G           = Game mode")
    print("    4           = Screensaver mode")
    print("    ESC         = Exit current mode (game/screensaver)")
    print("    Ctrl+Q      = Quit application")
    print("")
    print("=" * 60)
    print("")
    
    # 1. Configuration
    google_api_key = os.getenv("GOOGLE_API_KEY")
    elevenlabs_api_key = os.getenv("ELEVENLABS_API_KEY")

    if not google_api_key:
        print("Error: GOOGLE_API_KEY not found in .env file.")
        return
    if not elevenlabs_api_key:
        print("Error: ELEVENLABS_API_KEY not found in .env file.")
        return

    # 2. Initialize Gemini
    genai.configure(api_key=google_api_key)
    model = genai.GenerativeModel("gemini-2.0-flash-exp", system_instruction=SYSTEM_PROMPT)
    chat = model.start_chat(history=[])

    # 3. Initialize ElevenLabs
    client = ElevenLabs(
        api_key=elevenlabs_api_key
    )

    # 4. Initialize Speech Recognition
    r = sr.Recognizer()
    mic = sr.Microphone()

    print("--- Engine Started ---")
    print("Hold SPACE to speak, release to process.")
    print("Press G for game mode, 4 for screensaver, Ctrl+Q to quit.")

    # Calibration
    with mic as source:
        print("Calibrating background noise... please wait.")
        r.adjust_for_ambient_noise(source, duration=2)
        print("Calibration complete.\n")

    # Set initial state to IDLE
    update_state(STATE_IDLE)
    
    last_interaction_time = time.time()
    
    # Tracks if we are currently manually in a mode (managed by sub-functions usually)
    # But for auto-screensaver we need to know if we are IDLE

    while True:
        try:
            current_time = time.time()
            
            # Check for Auto-Screensaver (20s idle)
            # Only if currently IDLE (state 0 implied by being in this loop and not other modes)
            if (current_time - last_interaction_time > 20):
                print("\n[AUTO] Idle for 20s - Starting screensaver...")
                run_screensaver_mode()
                last_interaction_time = time.time() # Reset on exit
                continue

            # Check for Ctrl+Q to quit (not just ESC)
            if keyboard.is_pressed('ctrl+q'):
                print("\nExiting...")
                break
            
            # Check for G to enter game mode
            if keyboard.is_pressed('g'):
                run_game_mode()
                last_interaction_time = time.time()
                time.sleep(0.3)  # Debounce
                continue
            
            # Check for 4 to enter screensaver
            if keyboard.is_pressed('4'):
                run_screensaver_mode()
                last_interaction_time = time.time()
                continue
            
            # Wait for SPACE to be pressed (push-to-talk)
            if not keyboard.is_pressed('space'):
                time.sleep(0.05)  # Small delay to avoid busy-waiting
                continue
            
            # Interaction started
            last_interaction_time = time.time()
            
            # SPACE is pressed - start listening
            # STATE: LISTENING (blue waveform)
            update_state(STATE_LISTENING)
            print("\n[LISTENING] Speak now... (release SPACE when done)")
            
            # Start audio level monitoring with sounddevice
            audio_stream = None
            try:
                import sounddevice as sd
                import numpy as np
                
                def audio_level_callback(indata, frames, time_info, status):
                    """Callback to monitor audio levels"""
                    try:
                        # Calculate RMS (root mean square) for audio level
                        rms = np.sqrt(np.mean(indata**2))
                        # Scale to 0-255 (increased sensitivity - rms * 4000)
                        level = min(255, max(0, int(rms * 4000)))
                        print(f"\r[LEVEL] {level:3d}", end="", flush=True)  # Debug output
                        vio_controller.set_amplitude(level)
                    except:
                        pass
                
                # Start non-blocking input stream for level monitoring
                audio_stream = sd.InputStream(
                    callback=audio_level_callback,
                    channels=1,
                    samplerate=16000,
                    blocksize=1024
                )
                audio_stream.start()
            except Exception as e:
                # Sounddevice not available, continue without level monitoring
                pass
            
            try:
                with mic as source:
                    # Wait for SPACE to be released, then capture what was said
                    # Use a longer timeout to capture the full phrase
                    audio = r.listen(source, timeout=10, phrase_time_limit=15)
            except sr.WaitTimeoutError:
                print("\nNo speech detected.")
                if audio_stream:
                    audio_stream.stop()
                    audio_stream.close()
                update_state(STATE_IDLE)
                vio_controller.set_amplitude(255)  # Reset to max
                last_interaction_time = time.time()
                continue
            except Exception as e:
                print(f"\nAudio capture error: {e}")
                if audio_stream:
                    audio_stream.stop()
                    audio_stream.close()
                update_state(STATE_IDLE)
                vio_controller.set_amplitude(255)  # Reset to max
                last_interaction_time = time.time()
                continue
            
            # Stop audio level monitoring
            if audio_stream:
                audio_stream.stop()
                audio_stream.close()
                audio_stream = None
            
            # Reset to IDLE amplitude (flat line)
            vio_controller.set_amplitude(128)

            # STATE: PROCESSING (Idle - flat line)
            update_state(STATE_IDLE)

            # STATE: PROCESSING (Idle - flat line)
            update_state(STATE_IDLE)
            print("[PROCESSING] Recognizing speech...")
            
            try:
                user_text = r.recognize_google(audio)
                print(f"You said: {user_text}")
                
                # Generate response from Gemini
                print("[THINKING] Generating response...")
                response = chat.send_message(user_text)
                raw_text = response.text
                
                # Parse mood and text
                mood, command, ai_text = parse_response(raw_text)
                
                if command.lower() == "game":
                    print("[CMD] AI starting GAME mode...")
                    # We speak first then launch game? Or launch game then speak?
                    # Speaking requires blocking usually. Let's speak then launch.
                    
                elif command.lower() == "screensaver":
                    print("[CMD] AI starting SCREENSAVER mode...")
                
                print(f"[{mood.upper()}] KAREN: {ai_text}")

                # Generate audio from ElevenLabs (with fallback to local TTS)
                print("[GENERATING] Creating speech...")
                use_local_tts = False
                audio_data = None
                
                try:
                    audio_bytes_gen = client.text_to_speech.convert(
                        text=ai_text,
                        voice_id="Cx2PEJFdr8frSuUVB6yZ",
                        model_id="eleven_multilingual_v2"
                    )
                    # Consume generator to get bytes
                    audio_data = b"".join(audio_bytes_gen)
                except Exception as api_error:
                    print(f"[API ERROR] ElevenLabs failed: {api_error}")
                    print("[FALLBACK] Using local Windows TTS...")
                    use_local_tts = True

                # STATE: SPEAKING - Use ANGRY state for angry mood, otherwise NEUTRAL

                if mood.lower() == "angry":
                    update_state(STATE_ANGRY)  # Red, chaotic waveform
                else:
                    update_state(STATE_NEUTRAL)  # Green, moderate waveform
                
                # Force amplitude to max so the waveform is visible (reset from listening)
                vio_controller.set_amplitude(255)
                
                print("[SPEAKING]...")
                # Play audio (ElevenLabs) or use local TTS
                if use_local_tts:
                    speak_local_tts(ai_text)
                else:
                    play_audio_bytes(audio_data)

                # Execute command if any (AFTER speaking)
                if command.lower() == "game":
                    time.sleep(0.5)
                    run_game_mode()
                    last_interaction_time = time.time()
                elif command.lower() == "screensaver":
                    time.sleep(0.5)
                    run_screensaver_mode()
                    last_interaction_time = time.time()

            except sr.UnknownValueError:
                print("Could not understand audio")
            except sr.RequestError as e:
                print(f"Speech recognition error: {e}")
            except Exception as e:
                print(f"Error in processing: {e}")
                import traceback
                traceback.print_exc()
                
            # STATE: IDLE (Done talking)
            update_state(STATE_IDLE)
            last_interaction_time = time.time()

        except KeyboardInterrupt:
            print("\nInterrupted by user.")
            break
        except Exception as e:
            print(f"An error occurred: {e}")
            update_state(STATE_IDLE)
            break
            
    update_state(STATE_IDLE)
    print("Goodbye!")

if __name__ == "__main__":
    main()
