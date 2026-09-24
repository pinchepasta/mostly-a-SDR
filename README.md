<h2>mostly-a-SDR</h2>

This tool makes your Raspberry Pi send and receive .sub files, fully compatible with Flipper Zero / mostly-a-Flipper & Bruce.

<img src="https://github.com/pinchepasta/mostly-a-SDR/blob/main/mostly-a-SDR.jpg" alt="Girl in a jacket" width="80%" height="80%">

<h2>What does it do?</h2>

It let's you send Flipper Zero compatible .sub files with absolutely no additional hardware needed. The tool uses rpitx as a base, and extends rpitx's functionality by a whole damn lot! 
You can also add an RTLSDR to the mix and make the device an RF Repeater, or just to save signals as .sub or .iq files.
But that's not all, the toolkit can do a lot more.
<br> <br>

<h2>Fully Flipper Zero compatible?</h2>
Yes, you can use all .sub files that work on Flipper Zero devices, and just copy them onto your mostly-a-SDR to transmit them. No additional steps or conversion needed.
<br> <br>

<h2>How to install?</h2>
Just git clone, unzip and go to /mostly-a-SDR and do chmod +x install.sh afterwards just type in ./install.sh and let it do it's thing.
If that succeeds, just type in ./start.sh to start the application.
<br> <br>

<h2>What do I need to get started?</h2>

Just your Raspberry Pi 3(b) / Raspberry Pi 4 or a Raspberry Pi 5. You can start to transmit with just this device alone, but it makes sense to throw an RTLSDR into the mix, to gain Rx functionality.
<br> <br>

<h2>That's it?</h2>
Nah, I'm going to write a more detailed readme soon. I'm on vacation.

By the way: <b>Next version will have full BLESP v3 integration and support, to seamlessly control your mostly-a-SDR device from your phone with a nice looking gui.</b>
