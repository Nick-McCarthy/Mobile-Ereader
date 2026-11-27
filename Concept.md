- create an Agents.md file to act as an index for the various agent helper files in /docs
-please create an action plan in /docs in this repo to achieve the below requirements

this repository is meant to be a native ereader for the iphone.

-the end result must be able to satisfy Apple security requirements
-tech stack is entirely optional and open to whatever best satisfies requirements.

the app should be able to store epub files on the device and link to a users google drive.

the user should be able to select a google drive or a subfolder in that drive and the app will find all epub files in that dir and it's sub dirs and pull the epubs (title, author, publication date, and cover) (use "unkonwn" or a placeholder if any of these fields are empty) and store them in a db (the covers may be stored locally if necasary) 

// the library page
    clicking a book should initiate it's download if it is not already downloaded
    clicking and holding the book should bring up a menu where the user can (edit it's details, add it to a collection, add it to a series)

    the library page should have these sort and view options
    
    //view
    -grid
    -list
    -collections

    //sort
    -recently viewed
    -title
    -author
    -publication date
    -downloaded/ not downloaded

    //clicking and holding down on a title should

    // the library page should have a search bar

//settings page
    //sync
    -way to link google drive
    -should have a sync button to sync with google drive 
    -some books store their authors names as "Last Name, First Name" 
    while others store them as just "First Name Last Name". I would like to have an option to force conformity on the client side. ie: mark which way the name is stored on the epub and by changing a setting on the app they will appear in the library as either or uniformally.
    -should have a way to create a collection
    -should have a way to create a series

//collections page 
    -should be able to view your collections in a collapsible accordian, or some other form that is comfortable to navigate (i do not have a strong preference here and am open to whatever the agent thinks will be the most effective layout)

//ereader page
    -if possible use a prexisting library that has maximum flexiblity 
    - the below tools should only be visible when taping on the page, draging left or right should only change the page and not make the tools appear
    -should have a back button to return to library
    -should have an "Aa" button that pulls up a drawer with tabs (font, layout)
        //font
        -should control (font, size, spacing)
        //layout
        -should control (page color, continuous scrolling, alignment, orientation lock)
    -a button to create a book mark
    -should have a bookmark button that pulls out a drawer were the user can scroll through and select a bookmark from all the bookmarks they have left in that book
    -should have a navigation button that pulls up a drawer containing chapter navigation
    -at the bottom should have a dragable progress bar with visible completion percentage
