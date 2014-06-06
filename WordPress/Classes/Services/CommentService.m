#import "CommentService.h"
#import "Blog.h"
#import "Comment.h"
#import "CommentServiceRemote.h"
#import "CommentServiceRemoteXMLRPC.h"
#import "CommentServiceRemoteREST.h"
#import "ContextManager.h"

@interface CommentService ()

@property (nonatomic, strong) NSManagedObjectContext *managedObjectContext;

@end

@implementation CommentService

- (id)initWithManagedObjectContext:(NSManagedObjectContext *)context {
    self = [super init];
    if (self) {
        _managedObjectContext = context;
    }

    return self;
}

// Create comment
- (Comment *)createCommentForBlog:(Blog *)blog {
    Comment *comment = [NSEntityDescription insertNewObjectForEntityForName:NSStringFromClass([Comment class]) inManagedObjectContext:blog.managedObjectContext];
    comment.blog = blog;
    return comment;
}

// Create reply
- (Comment *)createReplyForComment:(Comment *)comment {
    Comment *reply = [self createCommentForBlog:comment.blog];
    reply.postID = comment.postID;
    reply.post = comment.post;
    reply.parentID = comment.commentID;
    reply.status = CommentStatusApproved;
    return reply;
}

// Restore draft reply
- (Comment *)restoreReplyForComment:(Comment *)comment {
    NSFetchRequest *existingReply = [NSFetchRequest fetchRequestWithEntityName:NSStringFromClass([Comment class])];
    existingReply.predicate = [NSPredicate predicateWithFormat:@"status == %@ AND parentID == %@", CommentStatusDraft, comment.commentID];
    existingReply.fetchLimit = 1;

    NSError *error;
    NSArray *replies = [self.managedObjectContext executeFetchRequest:existingReply error:&error];
    if (error) {
        DDLogError(@"Failed to fetch reply: %@", error);
    }

    Comment *reply = [replies firstObject];
    if (!reply) {
        reply = [self createReplyForComment:comment];
    }

    reply.status = CommentStatusDraft;

    return reply;

}

// Sync comments
- (void)syncCommentsForBlog:(Blog *)blog
                    success:(void (^)())success
                    failure:(void (^)(NSError *error))failure {
    id<CommentServiceRemote> remote = [self remoteForBlog:blog];
    [remote getCommentsForBlog:blog
                       success:^(NSArray *comments) {
                           [self.managedObjectContext performBlock:^{
                               [self mergeComments:comments forBlog:blog completionHandler:success];
                           }];
                       } failure:^(NSError *error) {
                           if (failure) {
                               [self.managedObjectContext performBlock:^{
                                   failure(error);
                               }];
                           }
                       }];
}

#pragma mark - Private methods

- (void)mergeComments:(NSArray *)comments forBlog:(Blog *)blog completionHandler:(void (^)(void))completion {
    NSMutableArray *commentsToKeep = [NSMutableArray array];
    for (RemoteComment *remoteComment in comments) {
        Comment *comment = [self findCommentWithID:remoteComment.commentID inBlog:blog];
        if (!comment) {
            [self createCommentForBlog:blog];
        }
        [self updateComment:comment withRemoteComment:remoteComment];
        [commentsToKeep addObject:comment];
    }

    NSSet *existingComments = blog.comments;
    if (existingComments && (existingComments.count > 0)) {
        for (Comment *comment in existingComments) {
            // Don't delete unpublished comments
            if(![commentsToKeep containsObject:comment] && comment.commentID != nil) {
                DDLogInfo(@"Deleting Comment: %@", comment);
                [self.managedObjectContext deleteObject:comment];
            }
        }
    }

    [[ContextManager sharedInstance] saveDerivedContext:self.managedObjectContext];

    if (completion) {
        dispatch_async(dispatch_get_main_queue(), completion);
    }
}

- (Comment *)findCommentWithID:(NSNumber *)commentID inBlog:(Blog *)blog {
    NSSet *comments = [blog.comments filteredSetUsingPredicate:[NSPredicate predicateWithFormat:@"commentID = %@", commentID]];
    return [comments anyObject];
}

- (void)updateComment:(Comment *)comment withRemoteComment:(RemoteComment *)remoteComment {
    comment.commentID = remoteComment.commentID;
    comment.author = remoteComment.author;
    comment.author_email = remoteComment.authorEmail;
    comment.author_url = remoteComment.authorUrl;
    comment.content = remoteComment.content;
    comment.dateCreated = remoteComment.date;
    comment.link = remoteComment.link;
    comment.parentID = remoteComment.parentID;
    comment.postID = remoteComment.postID;
    comment.postTitle = remoteComment.postTitle;
    comment.status = remoteComment.status;
    comment.type = remoteComment.type;
}

- (id<CommentServiceRemote>)remoteForBlog:(Blog *)blog {
    id<CommentServiceRemote>remote;
    // TODO: refactor API creation so it's not part of the model
    if (blog.restApi) {
        remote = [[CommentServiceRemoteREST alloc] initWithApi:blog.restApi];
    } else {
        WPXMLRPCClient *client = [WPXMLRPCClient clientWithXMLRPCEndpoint:[NSURL URLWithString:blog.xmlrpc]];
        remote = [[CommentServiceRemoteXMLRPC alloc] initWithApi:client];
    }
    return remote;
}

@end
