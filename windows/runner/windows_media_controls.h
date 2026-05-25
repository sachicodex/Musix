#ifndef RUNNER_WINDOWS_MEDIA_CONTROLS_H_
#define RUNNER_WINDOWS_MEDIA_CONTROLS_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>

class WindowsMediaControls {
 public:
  WindowsMediaControls(HWND window, flutter::BinaryMessenger* messenger);
  ~WindowsMediaControls();

 private:
  using EncodableValue = flutter::EncodableValue;
  using EncodableMap = flutter::EncodableMap;
  using MethodCall = flutter::MethodCall<EncodableValue>;
  using MethodResult = flutter::MethodResult<EncodableValue>;

  void InitializeSmtc();
  void RegisterMethodHandler();
  void HandleMethodCall(const MethodCall& call,
                        std::unique_ptr<MethodResult> result);
  void UpdateMediaState(const EncodableMap& arguments);
  void ClearMediaState();
  void EmitAction(const std::string& action);

  static const EncodableValue* FindValue(const EncodableMap& arguments,
                                         const char* key);
  static std::optional<std::string> ReadString(const EncodableMap& arguments,
                                               const char* key);
  static std::optional<bool> ReadBool(const EncodableMap& arguments,
                                      const char* key);
  static std::optional<int64_t> ReadInt(const EncodableMap& arguments,
                                        const char* key);
  static winrt::Windows::Foundation::TimeSpan MillisecondsToTimeSpan(
      int64_t milliseconds);
  static winrt::Windows::Storage::Streams::RandomAccessStreamReference
  CreateThumbnailReference(const std::string& art_uri);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  winrt::Windows::Media::SystemMediaTransportControls controls_{nullptr};
  winrt::event_token button_pressed_token_{};
  bool button_pressed_registered_ = false;
  bool initialized_ = false;
};

#endif  // RUNNER_WINDOWS_MEDIA_CONTROLS_H_
