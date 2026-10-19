// The app is Rust (`roostr-ios` in RoostrWebsite/gpui, linked as
// libroostr_ios.a): this entry point only hands the process to it. It runs
// UIKit's main loop and never returns.
extern int roostr_main(void);

int main(void) {
	return roostr_main();
}
