//
// App.xaml.h
// Declaration of the App class.
//

#pragma once

#include "App.g.h"

namespace BlankAppCX
{
	/// <summary>
	/// Provides application-specific behavior to supplement the default Application class.
	/// </summary>
	ref class App sealed
	{
	public:
		virtual void OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs^ e) override;

	private:
		Microsoft::UI::Xaml::Window^ window{ nullptr };

	internal:
		App();
	};
}
