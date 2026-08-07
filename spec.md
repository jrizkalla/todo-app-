Build a TODO multiplatform Swift app.
The App should have a clean UI with nice animations heavily inspired by Things. And I care about the following features:

# Data

The app should use icloud and sync data between devices automatically.

# TODO contents

Each todo should have at least the following properties:

- Title
- Notes
- Completeness field: open, started, cancelled, or completed 
  This should present as a normal checklist item toggling between open & complete with an option to chose one of the other mode using a hidden access method such as a long press
- Assigned date and optionally, time
- Duration
- Due date and optionally, time
- A list of reminders where each reminder is one of:
    - A date and time
    - A location


TODOs can also have subtasks. If a TODO has a subtask it cannot be marked complete or cancelled unless all subtasks are also marked as complete or cancelled.
If a user tries to mark it as complete or cancelled, ask them if they also want to mark all subtasks as complete or cancelled.

A TODO can be upgraded to a project. Projects get treated like TODOs but they show up on the side menu.

# Organizations

Todos should be placed in one of the following spaces:
- "Inbox"
- "Anytime"
- Space

"Inbox" is where all unorganized todos go until they get reclassified.
TODOs that get assigned a date or a due date get placed in "Anytime".

Users can create as many spaces as needed.
Projects can either be outside spaces or they can be inside spaces.
But there should only be 1 level of nesting (spaces that have projects).

New todos should go into an inbox by default until they get scheduled. They are considered scheduled as soon as they get assigned to a project/space or as soon as they get a date or an assigned date.

# Create TODOs

There should be a floating button on the left to create TODOs.
Additionally, on launch, the app should scan system level reminders (with the lists being looked at configurable in settings).
Those reminders should show up in the inbox with a little import icon. Once imported, they should be deleted from the reminders app.
Imported reminders should keep as much information from the original reminder as possible such as due date.


# App organization

The app should have a left hamburger-style menu. The top items on the menu should be inbox, today, and this week.
After that, it should list all projects grouped by section with the ability for the user to reorder them.

The app should launch by default on today.


# Text Fields

Text fields should support markdown. Single line text fields like titles should just support simple markdown edits like bold, underline, strikeout, italics, and inline code.
Multiline fields should support more advanced markdown like sections, code blocks, etc.

On MacOS, text fields should have the option to turn on vim bindings.

On all platforms, add a listener to the title field. Automatically detect dates (including relative dates like "today" or "tomorrow"), parent project names, durations (e.g. 5 minutes, 5m).
Once a match is found, surface a small menu above the keyboard (on iOS & iPadOS) and at the bottom of the window on MacOS to suggest adding that property to the TODO.

For example, if the user types "Clean car tomorrow", surface 2 buttons. One that has a calendar and says "schedule tomorrow" and the other with a target icon that says "deadline tomorrow". If one of them is clicked, set the appropriate attribute and clear the word "tomorrow" from the title.


# Calendar view

Aside from typical list view. There should be a calendar view that shows a single day or a week.
The view should show all the scheduled TODOs without a time on the top and show the TODOs with a time like they are calendar events.
TODOs with a date & time but no duration should be shown with a default duration of 15 minutes (configurable in settings).

On bigger screens such as MacOS or iPadOS, there should be a hidable side view (on the right) that shows the inbox and overdue items.




# Future features

Design the app to support the following future features but do not implement them:
- Widgets
- A CLI interface on MacOS 
- Siri support with app intents
- Export of events (manually, into reminders or calendar events)

