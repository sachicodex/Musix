#include "windows_media_controls.h"

#include <SystemMediaTransportControlsInterop.h>
#include <windows.h>

#include <algorithm>
#include <chrono>
#include <utility>

namespace {

using EncodableValue = flutter::EncodableValue;
using EncodableMap = flutter::EncodableMap;

constexpr char kChannelName[] = "com.sachicodex.musix/windows_media_controls";

void DebugLog(const wchar_t* message) {
  OutputDebugStringW(message);
}

std::string ButtonToAction(
    winrt::Windows::Media::SystemMediaTransportControlsButton button) {
  using winrt::Windows::Media::SystemMediaTransportControlsButton;

  switch (button) {
    case SystemMediaTransportControlsButton::Play:
      return "play";
    case SystemMediaTransportControlsButton::Pause:
      return "pause";
    case SystemMediaTransportControlsButton::Next:
      return "next";
    case SystemMediaTransportControlsButton::Previous:
      return "previous";
    default:
      return std::string();
  }
}

}  // namespace

WindowsMediaControls::WindowsMediaControls(HWND window,
                                           flutter::BinaryMessenger* messenger)
    : window_(window),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger,
          kChannelName,
          &flutter::StandardMethodCodec::GetInstance())) {
  RegisterMethodHandler();
  try {
    InitializeSmtc();
    initialized_ = true;
  } catch (const winrt::hresult_error&) {
    DebugLog(L"[Musix] Windows media controls initialization failed.\n");
  } catch (...) {
    DebugLog(L"[Musix] Windows media controls initialization failed with an unknown error.\n");
  }
}

WindowsMediaControls::~WindowsMediaControls() {
  try {
    if (controls_ && button_pressed_registered_) {
      controls_.ButtonPressed(button_pressed_token_);
    }
  } catch (...) {
    DebugLog(L"[Musix] Windows media controls cleanup failed.\n");
  }
}

void WindowsMediaControls::InitializeSmtc() {
  auto interop = winrt::get_activation_factory<
      winrt::Windows::Media::SystemMediaTransportControls,
      ISystemMediaTransportControlsInterop>();

  void* raw_controls = nullptr;
  winrt::check_hresult(interop->GetForWindow(
      window_,
      winrt::guid_of<winrt::Windows::Media::ISystemMediaTransportControls>(),
      &raw_controls));

  controls_ = {raw_controls, winrt::take_ownership_from_abi};
  controls_.IsEnabled(false);
  controls_.IsPlayEnabled(true);
  controls_.IsPauseEnabled(true);
  controls_.IsNextEnabled(false);
  controls_.IsPreviousEnabled(false);
  controls_.IsStopEnabled(false);

  button_pressed_token_ = controls_.ButtonPressed(
      [this](winrt::Windows::Media::SystemMediaTransportControls const&,
             winrt::Windows::Media::
                 SystemMediaTransportControlsButtonPressedEventArgs const&
                     args) {
        const std::string action = ButtonToAction(args.Button());
        if (!action.empty()) {
          EmitAction(action);
        }
      });
  button_pressed_registered_ = true;
}

void WindowsMediaControls::RegisterMethodHandler() {
  channel_->SetMethodCallHandler(
      [this](const MethodCall& call, std::unique_ptr<MethodResult> result) {
        HandleMethodCall(call, std::move(result));
      });
}

void WindowsMediaControls::HandleMethodCall(
    const MethodCall& call,
    std::unique_ptr<MethodResult> result) {
  if (call.method_name() == "updateMediaState") {
    const auto* arguments = std::get_if<EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("bad-args", "Expected a map for updateMediaState.");
      return;
    }
    UpdateMediaState(*arguments);
    result->Success();
    return;
  }

  if (call.method_name() == "clearMediaState") {
    ClearMediaState();
    result->Success();
    return;
  }

  result->NotImplemented();
}

void WindowsMediaControls::UpdateMediaState(const EncodableMap& arguments) {
  if (!initialized_ || !controls_) {
    return;
  }

  try {
  const std::string title =
      ReadString(arguments, "title").value_or("Nothing playing");
  const std::string artist =
      ReadString(arguments, "artist").value_or("Unknown artist");
  const std::string album =
      ReadString(arguments, "album").value_or("Unknown album");
  const std::string art_uri = ReadString(arguments, "artUri").value_or("");
  const bool is_playing = ReadBool(arguments, "isPlaying").value_or(false);
  const int64_t position_ms =
      std::max<int64_t>(ReadInt(arguments, "positionMs").value_or(0), 0);
  const int64_t duration_ms =
      std::max<int64_t>(ReadInt(arguments, "durationMs").value_or(0), 0);
  const bool has_previous = ReadBool(arguments, "hasPrevious").value_or(false);
  const bool has_next = ReadBool(arguments, "hasNext").value_or(false);

  controls_.IsEnabled(true);
  controls_.PlaybackStatus(
      is_playing ? winrt::Windows::Media::MediaPlaybackStatus::Playing
                 : winrt::Windows::Media::MediaPlaybackStatus::Paused);
  controls_.IsPlayEnabled(!is_playing);
  controls_.IsPauseEnabled(is_playing);
  controls_.IsPreviousEnabled(has_previous);
  controls_.IsNextEnabled(has_next);

  auto updater = controls_.DisplayUpdater();
  updater.ClearAll();
  updater.Type(winrt::Windows::Media::MediaPlaybackType::Music);
  updater.MusicProperties().Title(winrt::to_hstring(title));
  updater.MusicProperties().Artist(winrt::to_hstring(artist));
  updater.MusicProperties().AlbumTitle(winrt::to_hstring(album));

  if (!art_uri.empty()) {
    auto thumbnail = CreateThumbnailReference(art_uri);
    if (thumbnail) {
      updater.Thumbnail(thumbnail);
    }
  }

  updater.Update();

  winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties timeline;
  timeline.StartTime(MillisecondsToTimeSpan(0));
  timeline.MinSeekTime(MillisecondsToTimeSpan(0));
  timeline.Position(MillisecondsToTimeSpan(
      duration_ms > 0 ? std::clamp(position_ms, int64_t{0}, duration_ms)
                      : position_ms));
  if (duration_ms > 0) {
    timeline.EndTime(MillisecondsToTimeSpan(duration_ms));
    timeline.MaxSeekTime(MillisecondsToTimeSpan(duration_ms));
  }
  controls_.UpdateTimelineProperties(timeline);
  } catch (const winrt::hresult_error&) {
    DebugLog(L"[Musix] Windows media controls update failed.\n");
    initialized_ = false;
  } catch (...) {
    DebugLog(L"[Musix] Windows media controls update failed with an unknown error.\n");
    initialized_ = false;
  }
}

void WindowsMediaControls::ClearMediaState() {
  if (!initialized_ || !controls_) {
    return;
  }

  try {
    controls_.PlaybackStatus(
        winrt::Windows::Media::MediaPlaybackStatus::Closed);
    controls_.IsPlayEnabled(false);
    controls_.IsPauseEnabled(false);
    controls_.IsPreviousEnabled(false);
    controls_.IsNextEnabled(false);
    controls_.DisplayUpdater().ClearAll();
    controls_.DisplayUpdater().Update();
    controls_.IsEnabled(false);
  } catch (...) {
    DebugLog(L"[Musix] Windows media controls clear failed.\n");
    initialized_ = false;
  }
}

void WindowsMediaControls::EmitAction(const std::string& action) {
  try {
    EncodableMap payload = {
        {EncodableValue("action"), EncodableValue(action)},
    };
    channel_->InvokeMethod("mediaAction",
                           std::make_unique<EncodableValue>(std::move(payload)));
  } catch (...) {
    DebugLog(L"[Musix] Windows media controls action emit failed.\n");
  }
}

const EncodableValue* WindowsMediaControls::FindValue(
    const EncodableMap& arguments,
    const char* key) {
  const auto iterator = arguments.find(EncodableValue(std::string(key)));
  if (iterator == arguments.end()) {
    return nullptr;
  }
  return &iterator->second;
}

std::optional<std::string> WindowsMediaControls::ReadString(
    const EncodableMap& arguments,
    const char* key) {
  const EncodableValue* value = FindValue(arguments, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  if (const auto* string_value = std::get_if<std::string>(value)) {
    return *string_value;
  }
  return std::nullopt;
}

std::optional<bool> WindowsMediaControls::ReadBool(const EncodableMap& arguments,
                                                   const char* key) {
  const EncodableValue* value = FindValue(arguments, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  if (const auto* bool_value = std::get_if<bool>(value)) {
    return *bool_value;
  }
  return std::nullopt;
}

std::optional<int64_t> WindowsMediaControls::ReadInt(
    const EncodableMap& arguments,
    const char* key) {
  const EncodableValue* value = FindValue(arguments, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  if (const auto* int32_value = std::get_if<int32_t>(value)) {
    return static_cast<int64_t>(*int32_value);
  }
  if (const auto* int64_value = std::get_if<int64_t>(value)) {
    return *int64_value;
  }
  return std::nullopt;
}

winrt::Windows::Foundation::TimeSpan
WindowsMediaControls::MillisecondsToTimeSpan(int64_t milliseconds) {
  return std::chrono::duration_cast<winrt::Windows::Foundation::TimeSpan>(
      std::chrono::milliseconds(milliseconds));
}

winrt::Windows::Storage::Streams::RandomAccessStreamReference
WindowsMediaControls::CreateThumbnailReference(const std::string& art_uri) {
  try {
    const auto wide_uri = winrt::to_hstring(art_uri);
    if (art_uri.find("://") != std::string::npos) {
      return winrt::Windows::Storage::Streams::RandomAccessStreamReference::
          CreateFromUri(winrt::Windows::Foundation::Uri(wide_uri));
    }

    auto file = winrt::Windows::Storage::StorageFile::GetFileFromPathAsync(
                    wide_uri)
                    .get();
    return winrt::Windows::Storage::Streams::RandomAccessStreamReference::
        CreateFromFile(file);
  } catch (...) {
    return nullptr;
  }
}
