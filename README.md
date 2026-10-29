# BashBoard

BashBoard is a dashboard **written entirely  in Bash**, used for monitoring services in a homelab.

> You come home after a long day at work, excited for a plex movie night, and find out that your plex server is down...
>
> **FOR 3 DAYS.**
>
> Eyes half closed, you have to troubleshoot, and troubleshoot, and troubleshoot...

## Enough! BashBoard is here to save you.

It checks all of your services, on multiple levels:

1) **Is the vm even reachable?** maybe an unexpected shutdown?
2) **or maybe the vm is fine, and the service is down?** we will check that too!

**No more surprises.**

---

You provide the program at `./bashboard` an input file, in the same directory, `config.tsv` (tab seperated values).

It might take you some time to build it and map out your homelab, but man will it make your life easir - even if you never even use the BashBoard. just having an IP map of your homelab is a huge time saver when troubleshooting.

You get a **beautiful live updating dashboard.** that

1) will save your ass
2) will save your ass
3) looks cool

### What else do you need?

---

Alright enough propagnda, beacuse the real goal in mind was to **learn and develop in bash**.

> **To see - what can be done.**

and oh, turns out... **A lot.** bash is **Powerfull.**

If you want to dive deeper and find out what can be done with bash, and how you can do it too - you can check out my introduction to bash here -

https://fistook.dev/posts/7d8f0715-aad9-4bad-8466-56dd87e6a20c/

---

*have a bashed day!*

---

## Run BashBoard v1.0

See the [setup and usage guide](docs/USAGE.md) for dependencies, configuration, command-line options, and how the parallel snapshot works. Release changes are in [CHANGELOG.md](CHANGELOG.md).
