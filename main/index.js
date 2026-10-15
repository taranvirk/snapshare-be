const express = require("express");
const supa = require("../other/database.js");
const cors = require("cors");
const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
const allowedOrigins = (process.env.CLIENT_ORIGIN || "http://localhost:5174,http://127.0.0.1:5174")
    .split(",")
    .map((origin) => origin.trim());
app.use(cors({ origin: allowedOrigins, credentials: true }));
const port = Number(process.env.PORT) || 3000;

app.get("/", (req, res) => res.json({ name: "Snapshare API", status: "ok" }));
app.get("/health", (req, res) => res.json({ status: "ok", uptime: Math.round(process.uptime()) }));

app.get("/getUserInfo/:username", async function (req, res) {
    var username = req.params["username"];

    const { data, error } = await supa.supaClient
        .from("users123")
        .select()
        .eq("username", username);

    if (error) {
        res.status(500).json({ status: 500, error: "Unable to load user", data: [] });
    } else if (!data?.length) {
        res.status(404).json({
            status: 404,
            error: "Resource not found",
            data: [],
        });
    } else {
        res.status(200).json({
            status: 200,
            statusText: "OK",
            data,
        });
    }
});

app.get("/getUsername/:userId", async function (req, res) {
    var userId = req.params["userId"];

    const { data, error } = await supa.supaClient
        .from("users123")
        .select("username")
        .eq("user_id", userId);

    if (error) {
        res.status(500).json({ status: 500, error: "Unable to load user", data: [] });
    } else if (!data?.length) {
        res.status(404).json({
            status: 404,
            error: "User not found",
            data: [],
        });
    } else {
        res.status(200).json({
            status: 200,
            statusText: "OK",
            data,
        });
    }
});

app.get("/getAllPosts", async function (req, res) {
    const data = await supa.supaClient.from("posts").select("*");

    if (data["data"][0] === null || data === null) {
        res.send({
            error: null,
            data: [],
            count: null,
            status: 400,
            statusText: "Error",
        });
        return;
    }

    res.send(data);
});

app.get("/getPost/:postId", async function (req, res) {
    const postId = req.params["postId"];

    const { data, error } = await supa.supaClient
        .from("posts")
        .select()
        .eq("post_id", postId);

    if (error) {
        res.status(500).json({ status: 500, error: "Unable to load post", data: [] });
    } else if (!data?.length) {
        res.status(404).json({
            status: 404,
            error: "Post not found",
            data: [],
        });
    } else {
        res.status(200).json({
            status: 200,
            statusText: "OK",
            data,
        });
    }
});

app.post("/signUpUserInfo", async function (req, res) {
    var username = req.body["username"];
    var email = req.body["email"];
    var passwordHash = req.body["password_hash"];
    var bio = req.body["bio"];
    var pic = req.body["img_url"];

    const { error } = await supa.supaClient.from("users").insert({
        username: username,
        email: email,
        password_hash: passwordHash,
        user_bio: bio,
        profile_picture_url: pic,
    });
    if (error == null) {
        res.send({
            error: null,
            data: [],
            count: null,
            status: 200,
            statusText: "OK",
        });
    } else {
        console.log(error);
        res.send({
            error: null,
            data: [error],
            count: null,
            status: 400,
            statusText: "Error",
        });
    }
});

app.post("/updateUserInfo", async function (req, res) {
    var username = req.body["username"];
    var newUsername = req.body["newUsername"];
    var email = req.body["email"];
    var bio = req.body["bio"];
    var pic = req.body["img_url"];

    const { error } = await supa.supaClient
        .from("users")
        .update({
            username: newUsername,
            email: email,
            user_bio: bio,
            profile_picture_url: pic,
        })
        .eq("username", username);

    if (error == null) {
        res.send({
            error: null,
            data: [],
            count: null,
            status: 200,
            statusText: "OK",
        });
    } else {
        res.send({
            error: null,
            data: [error],
            count: null,
            status: 400,
            statusText: "Error",
        });
    }
});

app.get("/getUserPosts/:username", async function (req, res) {
    var username = req.params["username"];

    const data = await supa.supaClient
        .from("users123")
        .select("user_id")
        .eq("username", username);

    if (data.data.length === 0) {
        res.status(404).json({
            status: 404,
            error: "Resource not found",
            data: [],
        });
        return;
    }

    var userId = data["data"][0]["user_id"];

    const posts = await supa.supaClient
        .from("posts")
        .select()
        .eq("user_id", userId);
    if (posts.data.length === 0) {
        res.status(400).json({
            status: 400,
            statusText: "No posts yet",
        });
    } else {
        res.status(200).json({
            status: 200,
            statusText: "OK",
            data: posts.data,
        });
    }
});

app.get("/getTotalFollowers/:username", async function (req, res) {
    var username = req.params["username"];

    const data = await supa.supaClient
        .from("users")
        .select("user_id")
        .eq("username", username);

    if (data["data"][0] == null) {
        res.send({
            error: null,
            data: ["User does not exist"],
            count: null,
            status: 400,
            statusText: "Error",
        });
        return;
    }

    var userId = data["data"][0]["user_id"];

    const { count, error } = await supa.supaClient
        .from("followers")
        .select("*", { count: "exact", head: true })
        .eq("user_id", userId);
    res.send({
        error: null,
        data: [count.toString()],
        count: null,
        status: 200,
        statusText: "OK",
    });
});

app.delete("/deleteUser/:userId", async function (req, res) {
    const userId = req.params["userId"];

    try {
        // Delete from followers
        await supa.supaClient
            .from('followers')
            .delete()
            .eq('follower_id', userId)

        await supa.supaClient
            .from('followers')
            .delete()
            .eq('following_id', userId)

        await supa.supaClient
            .from('direct_messages')
            .delete()
            .eq('sendingUserId', userId)
        
        await supa.supaClient
            .from('direct_messages')
            .delete()
            .eq('recievingUserId', userId)

        await supa.supaClient
            .from('comments_test')
            .delete()
            .eq('user_id', userId)

            // Delete from posts
        await supa.supaClient
            .from('posts')
            .delete()
            .eq('user_id', userId);

        await supa.supaClient
            .from('user_likes')
            .delete()
            .eq('user_id', userId)

        // Delete from likes
        const posts = await supa.supaClient
            .from('user_likes')
            .select('post_id')
            .eq('user_id', userId) 

        for (let i = 0; i < posts.data.length; i++) {
            const postId = posts.data[i].post_id;
        
            // Retrieve the current like_count
            const currentLikeCount = await supa.supaClient
                .from('likes')
                .select('like_count')
                .eq('post_id', postId)
                .single()

          // Update the like_count by decrementing it
            await supa.supaClient
                .from('likes')
                .update({ like_count: currentLikeCount.data.like_count - 1 })
                .eq('post_id', postId);
        }
		
        // Delete from users123
        await supa.supaClient
          .from('users123')
          .delete()
          .eq('user_id', userId);

      // Delete user from authentication
        const { data } = await supa.supaClient.auth.admin.deleteUser(userId);

        res.status(200).json({ success: true, message: 'User deleted successfully' });
    } catch (error) {
        console.error("Error deleting user:", error);
        res.status(500).json({ success: false, message: 'Internal server error' });
    }
});

app.get("/getFollowerList/:username", async function (req, res) {
    var username = req.params["username"];

    const data = await supa.supaClient
        .from("users")
        .select("user_id")
        .eq("username", username);

    if (data["data"][0] == null) {
        res.send({
            error: null,
            data: ["User does not exist"],
            count: null,
            status: 400,
            statusText: "Error",
        });
        return;
    }

    var userId = data["data"][0]["user_id"];

    const followingUsers = await supa.supaClient
        .from("followers")
        .select("follower_user_id")
        .eq("user_id", userId);

    var arr = [];

    for (let i = 0; i < followingUsers["data"].length; i++) {
        const followingUsername = await supa.supaClient
            .from("users")
            .select("username")
            .eq("user_id", followingUsers["data"][i]["follower_user_id"]);

        arr.push(followingUsername);
    }

    res.send(arr);
});

app.get("/getFollowingList/:userID", async function (req, res) {
    var userID = req.params["userID"];

    const followerList = await supa.supaClient
        .from("followers")
        .select("following_id")
        .eq("follower_id", userID);

    res.send(followerList);
});

app.listen(port, function () {
    console.log("listening on :" + port);
});
